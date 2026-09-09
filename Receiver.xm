#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>

static NSString * const ATRBundleID = @"com.alltrails.AllTrails";
static NSString * const ATRNotifyPrefix = @"com.551.alltrailsapptweak";
static NSString * const ATRSearchNotify = @"com.551.alltrailsapptweak.search";
static const NSUInteger ATRMaxPendingBytes = 1024;
static const NSUInteger ATRMaxChunks = 128;

static NSString *ATRLastCapturedURL = nil;
static NSTimeInterval ATRLastCaptureTime = 0;
static NSMutableDictionary *ATROriginalIMPs = nil;
static NSMutableSet *ATRHookedSelectors = nil;
static BOOL ATRDidShowLoadedToast = NO;

static BOOL ATRIsAllTrailsProcess(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID length]) return NO;
    return [bundleID isEqualToString:ATRBundleID] ||
           [bundleID caseInsensitiveCompare:@"com.alltrails.alltrails"] == NSOrderedSame;
}

static BOOL ATRIsAllTrailsWebURL(NSURL *url) {
    if (!url) return NO;
    NSString *scheme = [[url scheme] lowercaseString];
    NSString *host = [[url host] lowercaseString];
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    return [host isEqualToString:@"alltrails.com"] ||
           [host isEqualToString:@"www.alltrails.com"] ||
           [host hasSuffix:@".alltrails.com"];
}

static NSString *ATRTrailNameFromURL(NSURL *url) {
    if (!ATRIsAllTrailsWebURL(url)) return nil;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [[url path] componentsSeparatedByString:@"/"]) {
        if ([part length]) [parts addObject:part];
    }

    BOOL hasTrailComponent = NO;
    for (NSString *part in parts) {
        if ([[part lowercaseString] isEqualToString:@"trail"]) {
            hasTrailComponent = YES;
            break;
        }
    }
    if (!hasTrailComponent || [parts count] < 2) return nil;

    NSString *slug = [parts lastObject];
    if (![slug length]) return nil;
    NSString *decoded = [slug stringByRemovingPercentEncoding] ?: slug;
    NSString *name = [decoded stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    name = [name stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    while ([name rangeOfString:@"  "].location != NSNotFound) {
        name = [name stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *ATRStateKey(NSString *suffix) {
    return [NSString stringWithFormat:@"%@.%@", ATRNotifyPrefix, suffix];
}

static BOOL ATRSetState(NSString *name, uint64_t state) {
    int token = 0;
    if (notify_register_check([name UTF8String], &token) != 0) return NO;
    int result = notify_set_state(token, state);
    notify_cancel(token);
    return result == 0;
}

static BOOL ATRWritePendingName(NSString *name) {
    if (![name length]) return NO;
    NSData *data = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (![data length] || [data length] > ATRMaxPendingBytes) return NO;

    NSUInteger chunks = ([data length] + 7) / 8;
    if (chunks > ATRMaxChunks) return NO;
    const uint8_t *bytes = (const uint8_t *)[data bytes];

    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t word = 0;
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, [data length] - offset);
        memcpy(&word, bytes + offset, count);
        NSString *key = ATRStateKey([NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]);
        if (!ATRSetState(key, word)) return NO;
    }

    if (!ATRSetState(ATRStateKey(@"length"), (uint64_t)[data length])) return NO;
    if (!ATRSetState(ATRStateKey(@"time"), (uint64_t)[[NSDate date] timeIntervalSince1970])) return NO;
    notify_post([ATRSearchNotify UTF8String]);
    return YES;
}

static void ATRCaptureURL(NSURL *url) {
    if (!ATRIsAllTrailsProcess() || !url) return;
    NSString *trailName = ATRTrailNameFromURL(url);
    if (![trailName length]) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *absolute = [url absoluteString] ?: @"";
    if ([ATRLastCapturedURL isEqualToString:absolute] && (now - ATRLastCaptureTime) < 8.0) return;

    ATRLastCapturedURL = [absolute copy];
    ATRLastCaptureTime = now;
    ATRWritePendingName(trailName);
}

static void ATRCaptureObject(id object, NSUInteger depth) {
    if (!object || depth > 4) return;
    if ([object isKindOfClass:[NSURL class]]) {
        ATRCaptureURL((NSURL *)object);
        return;
    }
    if ([object isKindOfClass:[NSString class]]) {
        NSString *text = (NSString *)object;
        if ([text rangeOfString:@"alltrails.com" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            ATRCaptureURL([NSURL URLWithString:text]);
        }
        return;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)object;
        for (id key in dict) ATRCaptureObject([dict objectForKey:key], depth + 1);
        return;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)object) ATRCaptureObject(value, depth + 1);
        return;
    }
    if ([object isKindOfClass:[NSSet class]]) {
        for (id value in (NSSet *)object) ATRCaptureObject(value, depth + 1);
    }
}

static void ATRCaptureActivity(NSUserActivity *activity) {
    if (!activity) return;
    ATRCaptureURL([activity webpageURL]);
    ATRCaptureObject([activity userInfo], 0);
}

static NSString *ATRHookKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%p|%@", cls, NSStringFromSelector(selector)];
}

static IMP ATRGetOriginalIMP(id object, SEL selector) {
    if (!object || !selector) return NULL;
    Class cls = object_getClass(object);
    while (cls) {
        NSValue *value = [ATROriginalIMPs objectForKey:ATRHookKey(cls, selector)];
        if (value) {
            IMP original = NULL;
            [value getValue:&original];
            return original;
        }
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void ATRHookSelector(Class cls, SEL selector, IMP replacement) {
    if (!cls || !selector || !replacement) return;
    NSString *key = ATRHookKey(cls, selector);
    if ([ATRHookedSelectors containsObject:key]) return;

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (!original || !types || original == replacement) return;

    class_addMethod(cls, selector, original, types);
    Method target = class_getInstanceMethod(cls, selector);
    if (!target) return;

    NSValue *boxed = [NSValue value:&original withObjCType:@encode(IMP)];
    [ATROriginalIMPs setObject:boxed forKey:key];
    method_setImplementation(target, replacement);
    [ATRHookedSelectors addObject:key];
}

typedef BOOL (*ATRAppContinueIMP)(id, SEL, UIApplication *, NSUserActivity *, void (^)(NSArray *));
typedef BOOL (*ATRAppOpenURLIMP)(id, SEL, UIApplication *, NSURL *, NSDictionary *);
typedef void (*ATRSceneContinueIMP)(id, SEL, UIScene *, NSUserActivity *);
typedef void (*ATRSceneOpenContextsIMP)(id, SEL, UIScene *, NSSet *);

static BOOL ATRAppContinue(id self, SEL _cmd, UIApplication *application, NSUserActivity *activity, void (^restorationHandler)(NSArray *)) {
    ATRCaptureActivity(activity);
    ATRAppContinueIMP original = (ATRAppContinueIMP)ATRGetOriginalIMP(self, _cmd);
    return original ? original(self, _cmd, application, activity, restorationHandler) : NO;
}

static BOOL ATRAppOpenURL(id self, SEL _cmd, UIApplication *application, NSURL *url, NSDictionary *options) {
    ATRCaptureURL(url);
    ATRAppOpenURLIMP original = (ATRAppOpenURLIMP)ATRGetOriginalIMP(self, _cmd);
    return original ? original(self, _cmd, application, url, options) : NO;
}

static void ATRSceneContinue(id self, SEL _cmd, UIScene *scene, NSUserActivity *activity) {
    ATRCaptureActivity(activity);
    ATRSceneContinueIMP original = (ATRSceneContinueIMP)ATRGetOriginalIMP(self, _cmd);
    if (original) original(self, _cmd, scene, activity);
}

static void ATRSceneOpenContexts(id self, SEL _cmd, UIScene *scene, NSSet *contexts) {
    SEL urlSelector = NSSelectorFromString(@"URL");
    for (id context in contexts) {
        if ([context respondsToSelector:urlSelector]) {
            NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(context, urlSelector);
            ATRCaptureURL(url);
        }
    }
    ATRSceneOpenContextsIMP original = (ATRSceneOpenContextsIMP)ATRGetOriginalIMP(self, _cmd);
    if (original) original(self, _cmd, scene, contexts);
}

static void ATRInstallDelegateHooks(id delegate) {
    if (!delegate || !ATRIsAllTrailsProcess()) return;
    Class cls = object_getClass(delegate);
    ATRHookSelector(cls, @selector(application:continueUserActivity:restorationHandler:), (IMP)ATRAppContinue);
    ATRHookSelector(cls, @selector(application:openURL:options:), (IMP)ATRAppOpenURL);
    ATRHookSelector(cls, @selector(scene:continueUserActivity:), (IMP)ATRSceneContinue);
    ATRHookSelector(cls, @selector(scene:openURLContexts:), (IMP)ATRSceneOpenContexts);
}

static UIWindow *ATRWindow(void) {
    UIApplication *application = [UIApplication sharedApplication];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [application connectedScenes]) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in [(UIWindowScene *)scene windows]) {
                if ([window isKeyWindow]) return window;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [application keyWindow];
#pragma clang diagnostic pop
}

static void ATRShowLoadedToast(void) {
    if (ATRDidShowLoadedToast || !ATRIsAllTrailsProcess()) return;
    UIWindow *window = ATRWindow();
    if (!window) return;
    ATRDidShowLoadedToast = YES;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    [label setText:@"AllTrails link fix 1.0.18 loaded"];
    [label setTextAlignment:NSTextAlignmentCenter];
    [label setFont:[UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold]];
    [label setTextColor:[UIColor whiteColor]];
    [label setBackgroundColor:[UIColor colorWithWhite:0.08 alpha:0.90]];
    [[label layer] setCornerRadius:10.0];
    [[label layer] setMasksToBounds:YES];

    CGFloat width = MIN(CGRectGetWidth([window bounds]) - 32.0, 290.0);
    CGFloat top = [window safeAreaInsets].top + 8.0;
    [label setFrame:CGRectMake((CGRectGetWidth([window bounds]) - width) * 0.5, top, width, 34.0)];
    [window addSubview:label];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [label removeFromSuperview];
    });
}

static void ATRScanDelegates(void) {
    if (!ATRIsAllTrailsProcess()) return;
    UIApplication *application = [UIApplication sharedApplication];
    ATRInstallDelegateHooks([application delegate]);

    if (@available(iOS 13.0, *)) {
        SEL delegateSelector = NSSelectorFromString(@"delegate");
        for (UIScene *scene in [application connectedScenes]) {
            if ([scene respondsToSelector:delegateSelector]) {
                id delegate = ((id (*)(id, SEL))objc_msgSend)(scene, delegateSelector);
                ATRInstallDelegateHooks(delegate);
            }
        }
    }
}

%hook NSUserActivity

- (NSURL *)webpageURL {
    NSURL *url = %orig;
    ATRCaptureURL(url);
    return url;
}

- (void)setWebpageURL:(NSURL *)url {
    %orig;
    ATRCaptureURL(url);
}

- (NSDictionary *)userInfo {
    NSDictionary *info = %orig;
    ATRCaptureObject(info, 0);
    return info;
}

%end

%ctor {
    if (!ATRIsAllTrailsProcess()) return;

    ATROriginalIMPs = [[NSMutableDictionary alloc] init];
    ATRHookedSelectors = [[NSMutableSet alloc] init];
    %init;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
        ATRScanDelegates();
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
        ATRScanDelegates();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ATRShowLoadedToast();
        });
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ATRScanDelegates();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.00 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ATRScanDelegates();
    });
}
