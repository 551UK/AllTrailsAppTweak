#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <notify.h>
#include <string.h>

static NSString * const ATAllTrailsBundleID = @"com.alltrails.AllTrails";
static NSString * const ATNotifyPrefix = @"com.551.alltrailsapptweak";
static NSString * const ATHandoffNotify = @"com.551.alltrailsapptweak.handoff";
static const NSUInteger ATMaxPendingBytes = 1024;
static const NSUInteger ATMaxChunks = 128;

static NSURL *ATPendingURL = nil;
static int ATDarwinToken = 0;
static NSUInteger ATRouteGeneration = 0;
static BOOL ATRouteInFlight = NO;

static BOOL ATIsAllTrailsProcess(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:ATAllTrailsBundleID];
}

static BOOL ATIsAllTrailsWebURL(NSURL *url) {
    if (!url) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    NSString *host = url.host.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    return [host isEqualToString:@"alltrails.com"] ||
           [host isEqualToString:@"www.alltrails.com"] ||
           [host hasSuffix:@".alltrails.com"];
}

static NSArray<NSString *> *ATPathParts(NSURL *url) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        if (part.length) [parts addObject:part];
    }
    return parts;
}

static NSInteger ATTrailIndex(NSURL *url) {
    NSArray<NSString *> *parts = ATPathParts(url);
    for (NSUInteger i = 0; i < parts.count; i++) {
        if ([parts[i].lowercaseString isEqualToString:@"trail"]) return (NSInteger)i;
    }
    return NSNotFound;
}

static NSString *ATDeepLinkPath(NSURL *url) {
    if (!ATIsAllTrailsWebURL(url)) return nil;
    NSArray<NSString *> *parts = ATPathParts(url);
    NSInteger index = ATTrailIndex(url);
    if (index == NSNotFound || (NSUInteger)index + 1 >= parts.count) return nil;
    NSArray<NSString *> *route = [parts subarrayWithRange:NSMakeRange((NSUInteger)index,
                                                                      parts.count - (NSUInteger)index)];
    return [route componentsJoinedByString:@"/"];
}

static NSURL *ATCanonicalURL(NSURL *url) {
    NSString *route = ATDeepLinkPath(url);
    if (!route.length) return nil;

    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"https";
    components.host = @"www.alltrails.com";
    components.path = [@"/" stringByAppendingString:route];
    return components.URL;
}

#pragma mark - Cross-process handoff

static NSString *ATStateKey(NSString *suffix) {
    return [NSString stringWithFormat:@"%@.%@", ATNotifyPrefix, suffix];
}

static BOOL ATSetState(NSString *name, uint64_t state) {
    int token = 0;
    if (notify_register_check(name.UTF8String, &token) != 0) return NO;
    int result = notify_set_state(token, state);
    notify_cancel(token);
    return result == 0;
}

static BOOL ATGetState(NSString *name, uint64_t *state) {
    if (!state) return NO;
    int token = 0;
    if (notify_register_check(name.UTF8String, &token) != 0) return NO;
    int result = notify_get_state(token, state);
    notify_cancel(token);
    return result == 0;
}

static BOOL ATWritePendingURL(NSURL *url) {
    if (!ATIsAllTrailsWebURL(url) || !ATDeepLinkPath(url).length) return NO;

    NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length || data.length > ATMaxPendingBytes) return NO;

    NSUInteger chunks = (data.length + 7) / 8;
    if (chunks > ATMaxChunks) return NO;

    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t word = 0;
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, data.length - offset);
        memcpy(&word, bytes + offset, count);
        if (!ATSetState(ATStateKey([NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), word)) return NO;
    }

    if (!ATSetState(ATStateKey(@"length"), (uint64_t)data.length)) return NO;
    if (!ATSetState(ATStateKey(@"time"), (uint64_t)[[NSDate date] timeIntervalSince1970])) return NO;

    notify_post(ATHandoffNotify.UTF8String);
    return YES;
}

static NSURL *ATReadPendingURL(void) {
    uint64_t length64 = 0;
    uint64_t time64 = 0;
    if (!ATGetState(ATStateKey(@"length"), &length64)) return nil;
    if (!ATGetState(ATStateKey(@"time"), &time64)) return nil;

    NSUInteger length = (NSUInteger)length64;
    if (!length || length > ATMaxPendingBytes) return nil;

    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - (NSTimeInterval)time64;
    if (age < -5.0 || age > 180.0) return nil;

    NSUInteger chunks = (length + 7) / 8;
    if (chunks > ATMaxChunks) return nil;

    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t word = 0;
        if (!ATGetState(ATStateKey([NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), &word)) return nil;
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, length - offset);
        memcpy(bytes + offset, &word, count);
    }

    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSURL *url = string.length ? [NSURL URLWithString:string] : nil;
    return (ATIsAllTrailsWebURL(url) && ATDeepLinkPath(url).length) ? url : nil;
}

static void ATAdoptPending(void) {
    NSURL *url = ATReadPendingURL();
    if (!url) return;

    if (![ATPendingURL.absoluteString isEqualToString:url.absoluteString]) {
        ATPendingURL = url;
        ATRouteGeneration++;
        ATRouteInFlight = NO;
    }
}

static void ATClearPending(NSUInteger generation) {
    if (generation != ATRouteGeneration) return;
    ATPendingURL = nil;
    ATRouteInFlight = NO;
    ATSetState(ATStateKey(@"length"), 0);
}

static BOOL ATLaunchAllTrails(void) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
    SEL openSelector = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSelector]) return NO;

    id workspace = ((id (*)(id, SEL))objc_msgSend)((id)workspaceClass, defaultSelector);
    if (!workspace || ![workspace respondsToSelector:openSelector]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSelector, ATAllTrailsBundleID);
}

#pragma mark - Branch routing

static id ATBranchInstance(void) {
    Class branchClass = NSClassFromString(@"Branch");
    SEL getInstance = NSSelectorFromString(@"getInstance");
    if (!branchClass || ![branchClass respondsToSelector:getInstance]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)branchClass, getInstance);
}

static NSDictionary *ATBranchParams(NSURL *url) {
    NSString *route = ATDeepLinkPath(url);
    NSURL *canonical = ATCanonicalURL(url);
    NSString *canonicalString = canonical.absoluteString ?: url.absoluteString ?: @"";
    if (!route.length || !canonicalString.length) return nil;

    return @{
        @"$canonical_url": canonicalString,
        @"$fallback_url": canonicalString,
        @"$desktop_url": canonicalString,
        @"$deeplink_path": route,
        @"$ios_deeplink_path": route,
        @"deeplink_path": route,
        @"path": route,
        @"url": canonicalString,
        @"canonical_url": canonicalString,
        @"trail_url": canonicalString,
        @"content_type": @"trail",
        @"type": @"trail"
    };
}

static BOOL ATFeedGeneratedBranchURL(NSString *urlString, NSUInteger generation) {
    if (generation != ATRouteGeneration || !urlString.length) return NO;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return NO;

    id branch = ATBranchInstance();
    if (!branch) return NO;

    SEL newSession = NSSelectorFromString(@"handleDeepLinkWithNewSession:");
    if ([branch respondsToSelector:newSession]) {
        BOOL handled = ((BOOL (*)(id, SEL, id))objc_msgSend)(branch, newSession, url);
        if (handled) {
            ATClearPending(generation);
            return YES;
        }
    }

    SEL handle = NSSelectorFromString(@"handleDeepLink:");
    if ([branch respondsToSelector:handle]) {
        BOOL handled = ((BOOL (*)(id, SEL, id))objc_msgSend)(branch, handle, url);
        if (handled) {
            ATClearPending(generation);
            return YES;
        }
    }

    SEL continueActivity = NSSelectorFromString(@"continueUserActivity:");
    if ([branch respondsToSelector:continueActivity]) {
        NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
        activity.webpageURL = url;
        BOOL handled = ((BOOL (*)(id, SEL, id))objc_msgSend)(branch, continueActivity, activity);
        if (handled) {
            ATClearPending(generation);
            return YES;
        }
    }

    return NO;
}

static void ATRetryBranchRoute(NSUInteger attempt);

static void ATBranchGenerationFinished(NSUInteger generation, NSUInteger attempt, NSString *shortURL, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != ATRouteGeneration) return;
        ATRouteInFlight = NO;
        if (!error && shortURL.length && ATFeedGeneratedBranchURL(shortURL, generation)) return;
        ATRetryBranchRoute(attempt + 1);
    });
}

static void ATGenerateBranchLink(NSUInteger generation, NSUInteger attempt) {
    if (generation != ATRouteGeneration || !ATPendingURL) return;

    id branch = ATBranchInstance();
    NSDictionary *params = ATBranchParams(ATPendingURL);
    if (!branch || !params.count) {
        ATRouteInFlight = NO;
        ATRetryBranchRoute(attempt + 1);
        return;
    }

    void (^callback)(NSString *, NSError *) = ^(NSString *shortURL, NSError *error) {
        ATBranchGenerationFinished(generation, attempt, shortURL, error);
    };

    SEL fullSelector = NSSelectorFromString(@"getShortURLWithParams:andTags:andChannel:andFeature:andStage:andCallback:");
    if ([branch respondsToSelector:fullSelector]) {
        ATRouteInFlight = YES;
        ((void (*)(id, SEL, id, id, id, id, id, id))objc_msgSend)(branch,
                                                                  fullSelector,
                                                                  params,
                                                                  nil,
                                                                  @"alltrailsapptweak",
                                                                  @"deeplink",
                                                                  nil,
                                                                  callback);
    } else {
        SEL legacySelector = NSSelectorFromString(@"getShortURLWithParams:andCallback:");
        if ([branch respondsToSelector:legacySelector]) {
            ATRouteInFlight = YES;
            ((void (*)(id, SEL, id, id))objc_msgSend)(branch, legacySelector, params, callback);
        } else {
            ATRouteInFlight = NO;
            ATRetryBranchRoute(attempt + 1);
            return;
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == ATRouteGeneration && ATRouteInFlight && ATPendingURL) {
            ATRouteInFlight = NO;
            ATRetryBranchRoute(attempt + 1);
        }
    });
}

static void ATRetryBranchRoute(NSUInteger attempt) {
    if (!ATIsAllTrailsProcess() || !ATPendingURL || ATRouteInFlight) return;
    if (attempt >= 20) return;

    NSUInteger generation = ATRouteGeneration;
    NSTimeInterval delay = attempt == 0 ? 1.0 : 0.6;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != ATRouteGeneration || !ATPendingURL || ATRouteInFlight) return;
        ATGenerateBranchLink(generation, attempt);
    });
}

static void ATStartPendingRoute(void) {
    if (!ATIsAllTrailsProcess()) return;
    ATAdoptPending();
    if (ATPendingURL) ATRetryBranchRoute(0);
}

#pragma mark - URL interception

%hook UIApplication

- (void)openURL:(NSURL *)url
        options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey, id> *)options
completionHandler:(void (^)(BOOL success))completion {

    if (ATIsAllTrailsProcess() || !ATIsAllTrailsWebURL(url) || !ATDeepLinkPath(url).length) {
        %orig;
        return;
    }

    if (!ATWritePendingURL(url)) {
        %orig;
        return;
    }

    if (ATLaunchAllTrails()) {
        if (completion) completion(YES);
        return;
    }

    NSURL *launcher = [NSURL URLWithString:@"alltrails://"];
    NSMutableDictionary *launchOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
    [launchOptions removeObjectForKey:UIApplicationOpenURLOptionUniversalLinksOnly];
    %orig(launcher, launchOptions, completion);
}

- (BOOL)openURL:(NSURL *)url {
    if (ATIsAllTrailsProcess() || !ATIsAllTrailsWebURL(url) || !ATDeepLinkPath(url).length) {
        return %orig;
    }

    if (!ATWritePendingURL(url)) return %orig;
    if (ATLaunchAllTrails()) return YES;
    return %orig([NSURL URLWithString:@"alltrails://"]);
}

%end

%ctor {
    %init;

    if (!ATIsAllTrailsProcess()) return;

    notify_register_dispatch(ATHandoffNotify.UTF8String,
                             &ATDarwinToken,
                             dispatch_get_main_queue(),
                             ^(__unused int token) {
        ATStartPendingRoute();
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ATStartPendingRoute();
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
        ATStartPendingRoute();
    });
}
