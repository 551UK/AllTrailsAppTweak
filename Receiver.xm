#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#include <string.h>

static NSString * const ATRBundleID = @"com.alltrails.AllTrails";
static NSString * const ATRNotifyPrefix = @"com.551.alltrailsapptweak";
static NSString * const ATRSearchNotify = @"com.551.alltrailsapptweak.search";
static const NSUInteger ATRMaxPendingBytes = 1024;
static const NSUInteger ATRMaxChunks = 128;

static NSString *ATRLastCapturedURL = nil;
static NSTimeInterval ATRLastCaptureTime = 0;

static BOOL ATRIsAllTrailsProcess(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    return [bundleID isEqualToString:ATRBundleID] ||
           [bundleID caseInsensitiveCompare:@"com.alltrails.alltrails"] == NSOrderedSame;
}

static BOOL ATRIsAllTrailsWebURL(NSURL *url) {
    if (!url) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    NSString *host = url.host.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    return [host isEqualToString:@"alltrails.com"] ||
           [host isEqualToString:@"www.alltrails.com"] ||
           [host hasSuffix:@".alltrails.com"];
}

static NSString *ATRTrailNameFromURL(NSURL *url) {
    if (!ATRIsAllTrailsWebURL(url)) return nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        if (part.length) [parts addObject:part];
    }

    NSInteger trailIndex = NSNotFound;
    for (NSUInteger i = 0; i < parts.count; i++) {
        if ([parts[i].lowercaseString isEqualToString:@"trail"]) {
            trailIndex = (NSInteger)i;
            break;
        }
    }
    if (trailIndex == NSNotFound || (NSUInteger)trailIndex + 1 >= parts.count) return nil;

    NSString *slug = parts.lastObject;
    if (!slug.length) return nil;

    NSString *decoded = [slug stringByRemovingPercentEncoding] ?: slug;
    NSString *name = [decoded stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    name = [name stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    while ([name containsString:@"  "]) {
        name = [name stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *ATRStateKey(NSString *suffix) {
    return [NSString stringWithFormat:@"%@.%@", ATRNotifyPrefix, suffix];
}

static BOOL ATRSetState(NSString *name, uint64_t state) {
    int token = 0;
    if (notify_register_check(name.UTF8String, &token) != 0) return NO;
    int result = notify_set_state(token, state);
    notify_cancel(token);
    return result == 0;
}

static BOOL ATRWritePendingName(NSString *name) {
    if (!name.length) return NO;

    NSData *data = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length || data.length > ATRMaxPendingBytes) return NO;

    NSUInteger chunks = (data.length + 7) / 8;
    if (chunks > ATRMaxChunks) return NO;

    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t word = 0;
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, data.length - offset);
        memcpy(&word, bytes + offset, count);
        if (!ATRSetState(ATRStateKey([NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), word)) return NO;
    }

    if (!ATRSetState(ATRStateKey(@"length"), (uint64_t)data.length)) return NO;
    if (!ATRSetState(ATRStateKey(@"time"), (uint64_t)[[NSDate date] timeIntervalSince1970])) return NO;
    notify_post(ATRSearchNotify.UTF8String);
    return YES;
}

static void ATRCaptureURL(NSURL *url) {
    if (!ATRIsAllTrailsProcess() || !url) return;

    NSString *trailName = ATRTrailNameFromURL(url);
    if (!trailName.length) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *absolute = url.absoluteString ?: @"";
    if ([ATRLastCapturedURL isEqualToString:absolute] && (now - ATRLastCaptureTime) < 8.0) return;

    ATRLastCapturedURL = [absolute copy];
    ATRLastCaptureTime = now;
    ATRWritePendingName(trailName);
}

// Universal links are delivered to iOS apps as NSUserActivity objects.
// Hooking the Foundation object itself avoids relying on the app's private
// AppDelegate/SceneDelegate class names and works for both cold and warm opens.
%hook NSUserActivity

- (NSURL *)webpageURL {
    NSURL *url = %orig;
    ATRCaptureURL(url);
    return url;
}

- (NSString *)activityType {
    NSString *type = %orig;
    if (ATRIsAllTrailsProcess() && [type isEqualToString:NSUserActivityTypeBrowsingWeb]) {
        NSURL *url = self.webpageURL;
        ATRCaptureURL(url);
    }
    return type;
}

%end
