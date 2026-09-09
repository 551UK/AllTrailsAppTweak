#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <string.h>

static NSString * const L19BundleID = @"com.alltrails.AllTrails";
static NSString * const L19Prefix = @"com.551.alltrailsapptweak";
static NSString * const L19SearchNotify = @"com.551.alltrailsapptweak.search";
static const NSUInteger L19MaxBytes = 1024;
static BOOL L19Driving = NO;
static NSUInteger L19Generation = 0;

static BOOL L19IsAllTrails(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (!bundleID.length) return NO;
    return [bundleID isEqualToString:L19BundleID] ||
           [bundleID caseInsensitiveCompare:@"com.alltrails.alltrails"] == NSOrderedSame;
}

static BOOL L19IsAllTrailsURL(NSURL *url) {
    if (!url) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    NSString *host = url.host.lowercaseString;
    if (([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) &&
        ([host isEqualToString:@"alltrails.com"] || [host isEqualToString:@"www.alltrails.com"] || [host hasSuffix:@".alltrails.com"])) return YES;
    return [scheme hasPrefix:@"alltrails"];
}

static NSString *L19TrailName(NSURL *url) {
    if (!L19IsAllTrailsURL(url)) return nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in url.path.pathComponents) {
        if (part.length && ![part isEqualToString:@"/"]) [parts addObject:part];
    }

    NSString *slug = nil;
    for (NSUInteger i = 0; i < parts.count; i++) {
        if ([parts[i].lowercaseString isEqualToString:@"trail"] && i + 1 < parts.count) {
            slug = parts.lastObject;
            break;
        }
    }

    if (!slug.length) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSArray<NSString *> *keys = @[@"url", @"link", @"deep_link_value", @"deeplink", @"target_url", @"redirect", @"redirect_url"];
        for (NSURLQueryItem *item in components.queryItems) {
            if (![keys containsObject:item.name.lowercaseString] || !item.value.length) continue;
            NSURL *nested = [NSURL URLWithString:item.value.stringByRemovingPercentEncoding ?: item.value];
            NSString *nestedName = L19TrailName(nested);
            if (nestedName.length) return nestedName;
        }
    }

    if (!slug.length) return nil;
    NSString *decoded = slug.stringByRemovingPercentEncoding ?: slug;
    NSString *name = [decoded stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    name = [name stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    while ([name containsString:@"  "]) name = [name stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    return [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *L19Key(NSString *suffix) {
    return [NSString stringWithFormat:@"%@.%@", L19Prefix, suffix];
}

static BOOL L19SetState(NSString *name, uint64_t state) {
    int token = 0;
    if (notify_register_check(name.UTF8String, &token) != 0) return NO;
    int result = notify_set_state(token, state);
    notify_cancel(token);
    return result == 0;
}

static BOOL L19GetState(NSString *name, uint64_t *state) {
    int token = 0;
    if (!state || notify_register_check(name.UTF8String, &token) != 0) return NO;
    int result = notify_get_state(token, state);
    notify_cancel(token);
    return result == 0;
}

static BOOL L19WritePending(NSString *name) {
    NSData *data = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length || data.length > L19MaxBytes) return NO;
    NSUInteger chunks = (data.length + 7) / 8;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t word = 0;
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, data.length - offset);
        memcpy(&word, bytes + offset, count);
        if (!L19SetState(L19Key([NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), word)) return NO;
    }
    if (!L19SetState(L19Key(@"length"), (uint64_t)data.length)) return NO;
    if (!L19SetState(L19Key(@"time"), (uint64_t)NSDate.date.timeIntervalSince1970)) return NO;
    notify_post(L19SearchNotify.UTF8String);
    return YES;
}

static NSString *L19ReadPending(void) {
    uint64_t length64 = 0, time64 = 0;
    if (!L19GetState(L19Key(@"length"), &length64) || !L19GetState(L19Key(@"time"), &time64)) return nil;
    NSUInteger length = (NSUInteger)length64;
    if (!length || length > L19MaxBytes) return nil;
    NSTimeInterval age = NSDate.date.timeIntervalSince1970 - (NSTimeInterval)time64;
    if (age < -5.0 || age > 180.0) return nil;

    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    NSUInteger chunks = (length + 7) / 8;
    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t word = 0;
        if (!L19GetState(L19Key([NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), &word)) return nil;
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, length - offset);
        memcpy(bytes + offset, &word, count);
    }
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static void L19CaptureURL(NSURL *url) {
    NSString *name = L19TrailName(url);
    if (name.length) L19WritePending(name);
}

static void L19CaptureActivity(NSUserActivity *activity) {
    if (!activity) return;
    L19CaptureURL(activity.webpageURL);
    for (id value in activity.userInfo.allValues) {
        if ([value isKindOfClass:NSURL.class]) L19CaptureURL(value);
        else if ([value isKindOfClass:NSString.class]) {
            NSString *text = value;
            if ([text rangeOfString:@"alltrails" options:NSCaseInsensitiveSearch].location != NSNotFound) L19CaptureURL([NSURL URLWithString:text]);
        }
    }
}

static UIWindow *L19Window(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) return window;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) if (!window.hidden && window.alpha > 0.05) return window;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow;
#pragma clang diagnostic pop
}

static BOOL L19Visible(UIView *view) {
    return view && view.window && !view.hidden && view.alpha > 0.05 && CGRectGetWidth(view.bounds) > 3.0 && CGRectGetHeight(view.bounds) > 3.0;
}

static NSString *L19Text(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) [parts addObject:((UILabel *)view).text];
    if ([view isKindOfClass:UIButton.class] && ((UIButton *)view).currentTitle.length) [parts addObject:((UIButton *)view).currentTitle];
    if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        if (field.placeholder.length) [parts addObject:field.placeholder];
        if (field.text.length) [parts addObject:field.text];
    }
    if ([view isKindOfClass:UISearchBar.class]) {
        UISearchBar *bar = (UISearchBar *)view;
        if (bar.placeholder.length) [parts addObject:bar.placeholder];
        if (bar.text.length) [parts addObject:bar.text];
    }
    if (view.accessibilityLabel.length) [parts addObject:view.accessibilityLabel];
    if (view.accessibilityValue.length) [parts addObject:view.accessibilityValue];
    return parts.count ? [parts componentsJoinedByString:@" "] : @"";
}

static NSString *L19Normalize(NSString *text) {
    NSString *lower = [text.lowercaseString stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:NSLocale.currentLocale];
    NSMutableString *out = [NSMutableString string];
    BOOL space = NO;
    NSCharacterSet *alpha = NSCharacterSet.alphanumericCharacterSet;
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ([alpha characterIsMember:c]) { [out appendFormat:@"%C", c]; space = NO; }
        else if (!space && out.length) { [out appendString:@" "]; space = YES; }
    }
    return [out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

static BOOL L19Contains(NSString *text, NSArray<NSString *> *needles) {
    NSString *lower = text.lowercaseString;
    for (NSString *needle in needles) if ([lower rangeOfString:needle].location != NSNotFound) return YES;
    return NO;
}

static UIView *L19Find(UIWindow *window, BOOL (^predicate)(UIView *)) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (L19Visible(view) && predicate(view)) return view;
        for (UIView *child in view.subviews.reverseObjectEnumerator) [stack addObject:child];
    }
    return nil;
}

static BOOL L19Activate(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UIControl.class]) {
            [(UIControl *)candidate sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        if ([candidate respondsToSelector:@selector(accessibilityActivate)] && [candidate accessibilityActivate]) return YES;
    }
    return NO;
}

static BOOL L19Matches(NSString *candidateText, NSString *query) {
    NSString *candidate = L19Normalize(candidateText), *wanted = L19Normalize(query);
    if (!candidate.length || !wanted.length) return NO;
    if ([candidate containsString:wanted]) return YES;
    NSSet *ignored = [NSSet setWithObjects:@"and", @"the", @"via", @"trail", @"circular", @"loop", nil];
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *token in [wanted componentsSeparatedByString:@" "]) if (token.length >= 3 && ![ignored containsObject:token]) [tokens addObject:token];
    NSUInteger matches = 0;
    for (NSString *token in tokens) if ([candidate containsString:token]) matches++;
    return tokens.count >= 2 && matches >= MAX((NSUInteger)2, (tokens.count + 1) / 2);
}

static void L19SubmitField(UITextField *field, NSString *query) {
    [field becomeFirstResponder];
    field.text = @"";
    [field sendActionsForControlEvents:UIControlEventEditingChanged];
    [field insertText:query];
    field.text = query;
    [field sendActionsForControlEvents:UIControlEventEditingChanged];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([field.delegate respondsToSelector:@selector(textFieldShouldReturn:)]) [field.delegate textFieldShouldReturn:field];
        [field sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
        [UIApplication.sharedApplication sendAction:NSSelectorFromString(@"insertNewline:") to:nil from:nil forEvent:nil];
    });
}

static void L19SubmitBar(UISearchBar *bar, NSString *query) {
    [bar becomeFirstResponder];
    bar.text = query;
    if (@available(iOS 13.0, *)) {
        bar.searchTextField.text = query;
        [bar.searchTextField sendActionsForControlEvents:UIControlEventEditingChanged];
    }
    if ([bar.delegate respondsToSelector:@selector(searchBar:textDidChange:)]) [bar.delegate searchBar:bar textDidChange:query];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([bar.delegate respondsToSelector:@selector(searchBarSearchButtonClicked:)]) [bar.delegate searchBarSearchButtonClicked:bar];
        [UIApplication.sharedApplication sendAction:NSSelectorFromString(@"insertNewline:") to:nil from:nil forEvent:nil];
    });
}

static void L19Drive(NSUInteger generation, NSUInteger attempt) {
    if (!L19IsAllTrails() || generation != L19Generation) { L19Driving = NO; return; }
    NSString *query = L19ReadPending();
    if (!query.length || attempt >= 70) { L19Driving = NO; return; }
    UIWindow *window = L19Window();
    if (!window) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ L19Drive(generation, attempt + 1); });
        return;
    }

    UIView *result = L19Find(window, ^BOOL(UIView *view) {
        if ([view isKindOfClass:UITextField.class] || [view isKindOfClass:UISearchBar.class]) return NO;
        return L19Matches(L19Text(view), query);
    });
    if (result && L19Activate(result)) {
        L19SetState(L19Key(@"length"), 0);
        L19Driving = NO;
        return;
    }

    UISearchBar *bar = (UISearchBar *)L19Find(window, ^BOOL(UIView *view) { return [view isKindOfClass:UISearchBar.class]; });
    if (bar) {
        if (![L19Normalize(bar.text) isEqualToString:L19Normalize(query)]) L19SubmitBar(bar, query);
    } else {
        UITextField *field = (UITextField *)L19Find(window, ^BOOL(UIView *view) {
            if (![view isKindOfClass:UITextField.class]) return NO;
            return L19Contains(L19Text(view), @[@"find cities", @"find city", @"search", @"trail", @"city", @"park", @"place", @"location"]);
        });
        if (field) {
            if (![L19Normalize(field.text) isEqualToString:L19Normalize(query)]) L19SubmitField(field, query);
        } else {
            UIView *findCities = L19Find(window, ^BOOL(UIView *view) {
                return L19Contains(L19Text(view), @[@"find cities", @"find city", @"find a city", @"find a trail", @"find trails", @"search"]);
            });
            if (findCities) L19Activate(findCities);
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.42 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ L19Drive(generation, attempt + 1); });
}

static void L19StartDrive(void) {
    if (!L19IsAllTrails() || !L19ReadPending().length) return;
    L19Generation++;
    if (L19Driving) return;
    L19Driving = YES;
    NSUInteger generation = L19Generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ L19Drive(generation, 0); });
}

%group LinkFix19

%hook LSApplicationWorkspace
- (BOOL)openURL:(NSURL *)url {
    if (!L19IsAllTrails()) L19CaptureURL(url);
    return %orig;
}
- (BOOL)openURL:(NSURL *)url withOptions:(NSDictionary *)options {
    if (!L19IsAllTrails()) L19CaptureURL(url);
    return %orig;
}
- (BOOL)openURL:(NSURL *)url withOptions:(NSDictionary *)options error:(NSError **)error {
    if (!L19IsAllTrails()) L19CaptureURL(url);
    return %orig;
}
- (void)openURL:(NSURL *)url configuration:(id)configuration completionHandler:(id)handler {
    if (!L19IsAllTrails()) L19CaptureURL(url);
    %orig;
}
- (void)_sf_openURL:(NSURL *)url withOptions:(NSDictionary *)options completionHandler:(id)handler {
    if (!L19IsAllTrails()) L19CaptureURL(url);
    %orig;
}
%end

%hook UISceneConnectionOptions
- (NSSet<NSUserActivity *> *)userActivities {
    NSSet<NSUserActivity *> *activities = %orig;
    if (L19IsAllTrails()) for (NSUserActivity *activity in activities) L19CaptureActivity(activity);
    return activities;
}
- (NSSet<UIOpenURLContext *> *)URLContexts {
    NSSet<UIOpenURLContext *> *contexts = %orig;
    if (L19IsAllTrails()) for (UIOpenURLContext *context in contexts) L19CaptureURL(context.URL);
    return contexts;
}
%end

%hook UILabel
- (void)setText:(NSString *)text {
    if (L19IsAllTrails() && [text isEqualToString:@"AllTrails link fix 1.0.18 loaded"]) text = @"AllTrails link fix 1.0.19 loaded";
    %orig(text);
}
%end

%end

%ctor {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    %init(LinkFix19);

    if (!L19IsAllTrails()) return;
    notify_register_dispatch(L19SearchNotify.UTF8String, NULL, dispatch_get_main_queue(), ^(__unused int token) { L19StartDrive(); });
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { L19StartDrive(); }];
    [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { L19StartDrive(); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ L19StartDrive(); });
}
