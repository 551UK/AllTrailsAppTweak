#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <string.h>

static NSString * const L20BundleID = @"com.alltrails.AllTrails";
static NSString * const L20Prefix = @"com.551.alltrailsapptweak";
static NSString * const L20SearchNotify = @"com.551.alltrailsapptweak.search";
static const NSUInteger L20MaxBytes = 1024;
static BOOL L20Driving = NO;
static NSUInteger L20Generation = 0;
static int L20NotifyToken = 0;
static BOOL L20ShownCaptureToast = NO;

static BOOL L20IsAllTrails(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (!bundleID.length) return NO;
    return [bundleID isEqualToString:L20BundleID] ||
           [bundleID caseInsensitiveCompare:@"com.alltrails.alltrails"] == NSOrderedSame;
}

static BOOL L20IsAllTrailsURL(NSURL *url) {
    if (!url) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    NSString *host = url.host.lowercaseString;
    if (([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) &&
        ([host isEqualToString:@"alltrails.com"] || [host isEqualToString:@"www.alltrails.com"] || [host hasSuffix:@".alltrails.com"])) return YES;
    return [scheme hasPrefix:@"alltrails"];
}

static NSString *L20TrailName(NSURL *url) {
    if (!L20IsAllTrailsURL(url)) return nil;
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
            NSString *decoded = item.value.stringByRemovingPercentEncoding ?: item.value;
            NSString *nested = L20TrailName([NSURL URLWithString:decoded]);
            if (nested.length) return nested;
        }
    }

    if (!slug.length) return nil;
    NSString *decoded = slug.stringByRemovingPercentEncoding ?: slug;
    NSString *name = [decoded stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    name = [name stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    while ([name containsString:@"  "]) name = [name stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    return [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *L20Key(NSString *suffix) {
    return [NSString stringWithFormat:@"%@.%@", L20Prefix, suffix];
}

static BOOL L20SetState(NSString *name, uint64_t state) {
    int token = 0;
    if (notify_register_check(name.UTF8String, &token) != 0) return NO;
    int result = notify_set_state(token, state);
    notify_cancel(token);
    return result == 0;
}

static BOOL L20GetState(NSString *name, uint64_t *state) {
    int token = 0;
    if (!state || notify_register_check(name.UTF8String, &token) != 0) return NO;
    int result = notify_get_state(token, state);
    notify_cancel(token);
    return result == 0;
}

static BOOL L20WritePending(NSString *name) {
    NSData *data = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length || data.length > L20MaxBytes) return NO;
    NSUInteger chunks = (data.length + 7) / 8;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t word = 0;
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, data.length - offset);
        memcpy(&word, bytes + offset, count);
        if (!L20SetState(L20Key([NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), word)) return NO;
    }
    if (!L20SetState(L20Key(@"length"), (uint64_t)data.length)) return NO;
    if (!L20SetState(L20Key(@"time"), (uint64_t)NSDate.date.timeIntervalSince1970)) return NO;
    notify_post(L20SearchNotify.UTF8String);
    return YES;
}

static NSString *L20ReadPending(void) {
    uint64_t length64 = 0, time64 = 0;
    if (!L20GetState(L20Key(@"length"), &length64) || !L20GetState(L20Key(@"time"), &time64)) return nil;
    NSUInteger length = (NSUInteger)length64;
    if (!length || length > L20MaxBytes) return nil;
    NSTimeInterval age = NSDate.date.timeIntervalSince1970 - (NSTimeInterval)time64;
    if (age < -5.0 || age > 180.0) return nil;

    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = (uint8_t *)data.mutableBytes;
    NSUInteger chunks = (length + 7) / 8;
    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t word = 0;
        if (!L20GetState(L20Key([NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), &word)) return nil;
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, length - offset);
        memcpy(bytes + offset, &word, count);
    }
    NSString *name = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static void L20CaptureURL(NSURL *url) {
    NSString *name = L20TrailName(url);
    if (name.length) L20WritePending(name);
}

static void L20CaptureActivity(NSUserActivity *activity) {
    if (!activity) return;
    L20CaptureURL(activity.webpageURL);
    for (id value in activity.userInfo.allValues) {
        if ([value isKindOfClass:NSURL.class]) L20CaptureURL(value);
        else if ([value isKindOfClass:NSString.class]) {
            NSString *text = value;
            if ([text rangeOfString:@"alltrails" options:NSCaseInsensitiveSearch].location != NSNotFound) L20CaptureURL([NSURL URLWithString:text]);
        }
    }
}

static UIWindow *L20Window(void) {
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
    if (app.keyWindow) return app.keyWindow;
    for (UIWindow *window in app.windows) if (!window.hidden && window.alpha > 0.05) return window;
#pragma clang diagnostic pop
    return nil;
}

static BOOL L20Visible(UIView *view) {
    if (!view || !view.window || view.hidden || view.alpha <= 0.05) return NO;
    CGRect r = [view convertRect:view.bounds toView:nil];
    return CGRectGetWidth(r) > 3.0 && CGRectGetHeight(r) > 3.0;
}

static NSString *L20Text(UIView *view) {
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
    if (view.accessibilityIdentifier.length) [parts addObject:view.accessibilityIdentifier];
    return parts.count ? [parts componentsJoinedByString:@" "] : @"";
}

static NSString *L20Normalize(NSString *text) {
    if (!text.length) return @"";
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

static BOOL L20Contains(NSString *text, NSArray<NSString *> *needles) {
    NSString *lower = text.lowercaseString;
    if (!lower.length) return NO;
    for (NSString *needle in needles) if ([lower rangeOfString:needle.lowercaseString].location != NSNotFound) return YES;
    return NO;
}

static UIView *L20Find(UIWindow *window, BOOL (^predicate)(UIView *)) {
    if (!window || !predicate) return nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (L20Visible(view) && predicate(view)) return view;
        for (UIView *child in view.subviews.reverseObjectEnumerator) [stack addObject:child];
    }
    return nil;
}

static BOOL L20FireTapGesture(UIView *view) {
    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        if (![gesture isKindOfClass:UITapGestureRecognizer.class] || !gesture.enabled) continue;
        @try {
            NSArray *targets = [gesture valueForKey:@"_targets"];
            for (id wrapper in targets) {
                Ivar targetIvar = class_getInstanceVariable([wrapper class], "_target");
                Ivar actionIvar = class_getInstanceVariable([wrapper class], "_action");
                if (!targetIvar || !actionIvar) continue;
                id target = object_getIvar(wrapper, targetIvar);
                ptrdiff_t offset = ivar_getOffset(actionIvar);
                uint8_t *base = (uint8_t *)(__bridge void *)wrapper;
                SEL action = *(SEL *)(base + offset);
                if (!target || !action || ![target respondsToSelector:action]) continue;
                const char *name = sel_getName(action);
                if (name && strchr(name, ':')) ((void (*)(id, SEL, id))objc_msgSend)(target, action, gesture);
                else ((void (*)(id, SEL))objc_msgSend)(target, action);
                return YES;
            }
        } @catch (__unused NSException *exception) {}
    }
    return NO;
}

static BOOL L20Activate(UIView *view) {
    if (!view) return NO;
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UIControl.class]) {
            [(UIControl *)candidate sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        if ([candidate isKindOfClass:UITableViewCell.class]) {
            UIView *parent = candidate.superview;
            while (parent && ![parent isKindOfClass:UITableView.class]) parent = parent.superview;
            UITableView *table = [parent isKindOfClass:UITableView.class] ? (UITableView *)parent : nil;
            NSIndexPath *path = table ? [table indexPathForCell:(UITableViewCell *)candidate] : nil;
            if (path && [table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                [table.delegate tableView:table didSelectRowAtIndexPath:path];
                return YES;
            }
        }
        if ([candidate isKindOfClass:UICollectionViewCell.class]) {
            UIView *parent = candidate.superview;
            while (parent && ![parent isKindOfClass:UICollectionView.class]) parent = parent.superview;
            UICollectionView *collection = [parent isKindOfClass:UICollectionView.class] ? (UICollectionView *)parent : nil;
            NSIndexPath *path = collection ? [collection indexPathForCell:(UICollectionViewCell *)candidate] : nil;
            if (path && [collection.delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                [collection.delegate collectionView:collection didSelectItemAtIndexPath:path];
                return YES;
            }
        }
        if ([candidate respondsToSelector:@selector(accessibilityActivate)] && [candidate accessibilityActivate]) return YES;
        if (L20FireTapGesture(candidate)) return YES;
    }
    return NO;
}

static BOOL L20ActivateAtPoint(UIWindow *window, CGPoint point) {
    UIView *hit = [window hitTest:point withEvent:nil];
    return hit ? L20Activate(hit) : NO;
}

static BOOL L20Matches(NSString *candidateText, NSString *query) {
    NSString *candidate = L20Normalize(candidateText), *wanted = L20Normalize(query);
    if (!candidate.length || !wanted.length) return NO;
    if ([candidate containsString:wanted]) return YES;
    NSSet *ignored = [NSSet setWithObjects:@"and", @"the", @"via", @"trail", @"circular", @"loop", nil];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *token in [wanted componentsSeparatedByString:@" "]) if (token.length >= 3 && ![ignored containsObject:token]) [tokens addObject:token];
    NSUInteger matches = 0;
    for (NSString *token in tokens) if ([candidate containsString:token]) matches++;
    return tokens.count >= 2 && matches >= MAX((NSUInteger)2, (tokens.count + 1) / 2);
}

static UITextField *L20BestField(UIWindow *window) {
    __block UITextField *best = nil;
    __block NSInteger bestScore = NSIntegerMin;
    CGFloat height = CGRectGetHeight(window.bounds);
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        for (UIView *child in view.subviews.reverseObjectEnumerator) [stack addObject:child];
        if (![view isKindOfClass:UITextField.class] || !L20Visible(view)) continue;
        UITextField *field = (UITextField *)view;
        NSString *text = L20Text(field);
        NSInteger score = 0;
        if (L20Contains(text, @[@"find cities", @"find city", @"search", @"trail", @"city", @"park", @"place", @"location"])) score += 180;
        NSString *className = NSStringFromClass(field.class).lowercaseString;
        if ([className containsString:@"search"] || [className containsString:@"query"]) score += 100;
        CGRect rect = [field convertRect:field.bounds toView:window];
        if (CGRectGetMidY(rect) < height * 0.42) score += 40;
        if (field.isFirstResponder) score += 90;
        if (field.secureTextEntry) score -= 400;
        if (score > bestScore) { bestScore = score; best = field; }
    }
    return bestScore >= 25 ? best : nil;
}

static void L20SubmitField(UITextField *field, NSString *query) {
    if (!field || !query.length) return;
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

static void L20SubmitBar(UISearchBar *bar, NSString *query) {
    if (!bar || !query.length) return;
    [bar becomeFirstResponder];
    bar.text = query;
    if (@available(iOS 13.0, *)) {
        bar.searchTextField.text = @"";
        [bar.searchTextField sendActionsForControlEvents:UIControlEventEditingChanged];
        [bar.searchTextField insertText:query];
        bar.searchTextField.text = query;
        [bar.searchTextField sendActionsForControlEvents:UIControlEventEditingChanged];
    }
    if ([bar.delegate respondsToSelector:@selector(searchBar:textDidChange:)]) [bar.delegate searchBar:bar textDidChange:query];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([bar.delegate respondsToSelector:@selector(searchBarSearchButtonClicked:)]) [bar.delegate searchBarSearchButtonClicked:bar];
        [UIApplication.sharedApplication sendAction:NSSelectorFromString(@"insertNewline:") to:nil from:nil forEvent:nil];
    });
}

static void L20Toast(NSString *text) {
    UIWindow *window = L20Window();
    if (!window || !text.length) return;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.90];
    label.layer.cornerRadius = 10.0;
    label.layer.masksToBounds = YES;
    CGFloat width = MIN(CGRectGetWidth(window.bounds) - 32.0, 320.0);
    label.frame = CGRectMake((CGRectGetWidth(window.bounds) - width) * 0.5, window.safeAreaInsets.top + 48.0, width, 34.0);
    [window addSubview:label];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [label removeFromSuperview]; });
}

static void L20Drive(NSUInteger generation, NSUInteger attempt) {
    if (!L20IsAllTrails() || generation != L20Generation) { L20Driving = NO; return; }
    NSString *query = L20ReadPending();
    if (!query.length || attempt >= 90) { L20Driving = NO; return; }
    UIWindow *window = L20Window();
    if (!window) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ L20Drive(generation, attempt + 1); });
        return;
    }

    if (!L20ShownCaptureToast) {
        L20ShownCaptureToast = YES;
        L20Toast(@"1.0.20 link captured — searching");
    }

    UIView *result = L20Find(window, ^BOOL(UIView *view) {
        if ([view isKindOfClass:UITextField.class] || [view isKindOfClass:UISearchBar.class]) return NO;
        return L20Matches(L20Text(view), query);
    });
    if (result && L20Activate(result)) {
        L20SetState(L20Key(@"length"), 0);
        L20Driving = NO;
        return;
    }

    UISearchBar *bar = (UISearchBar *)L20Find(window, ^BOOL(UIView *view) { return [view isKindOfClass:UISearchBar.class]; });
    if (bar) {
        if (![L20Normalize(bar.text) isEqualToString:L20Normalize(query)] || attempt % 14 == 0) L20SubmitBar(bar, query);
    } else {
        UITextField *field = L20BestField(window);
        if (field) {
            if (![L20Normalize(field.text) isEqualToString:L20Normalize(query)] || attempt % 14 == 0) L20SubmitField(field, query);
        } else {
            UIView *findCities = L20Find(window, ^BOOL(UIView *view) {
                return L20Contains(L20Text(view), @[@"find cities", @"find city", @"find a city", @"find a trail", @"find trails", @"search", @"where do you want to go"]);
            });
            BOOL activated = findCities ? L20Activate(findCities) : NO;
            if (!activated && attempt % 4 == 0) {
                CGFloat top = window.safeAreaInsets.top;
                CGFloat width = CGRectGetWidth(window.bounds);
                for (NSNumber *off in @[@70.0, @90.0, @110.0, @130.0]) {
                    if (L20ActivateAtPoint(window, CGPointMake(width * 0.50, top + off.doubleValue))) break;
                }
            }
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.42 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ L20Drive(generation, attempt + 1); });
}

static void L20StartDrive(void) {
    if (!L20IsAllTrails() || !L20ReadPending().length || L20Driving) return;
    L20Generation++;
    L20Driving = YES;
    L20ShownCaptureToast = NO;
    NSUInteger generation = L20Generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ L20Drive(generation, 0); });
}

%group LinkFix20

%hook LSApplicationWorkspace
- (BOOL)openURL:(NSURL *)url {
    if (!L20IsAllTrails()) L20CaptureURL(url);
    return %orig;
}
- (BOOL)openURL:(NSURL *)url withOptions:(NSDictionary *)options {
    if (!L20IsAllTrails()) L20CaptureURL(url);
    return %orig;
}
- (BOOL)openURL:(NSURL *)url withOptions:(NSDictionary *)options error:(NSError **)error {
    if (!L20IsAllTrails()) L20CaptureURL(url);
    return %orig;
}
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(NSDictionary *)options {
    if (!L20IsAllTrails()) L20CaptureURL(url);
    return %orig;
}
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(NSDictionary *)options error:(NSError **)error {
    if (!L20IsAllTrails()) L20CaptureURL(url);
    return %orig;
}
- (void)openURL:(NSURL *)url configuration:(id)configuration completionHandler:(id)handler {
    if (!L20IsAllTrails()) L20CaptureURL(url);
    %orig;
}
- (void)_sf_openURL:(NSURL *)url withOptions:(NSDictionary *)options completionHandler:(id)handler {
    if (!L20IsAllTrails()) L20CaptureURL(url);
    %orig;
}
%end

%hook UISceneConnectionOptions
- (NSSet<NSUserActivity *> *)userActivities {
    NSSet<NSUserActivity *> *activities = %orig;
    if (L20IsAllTrails()) for (NSUserActivity *activity in activities) L20CaptureActivity(activity);
    return activities;
}
- (NSSet<UIOpenURLContext *> *)URLContexts {
    NSSet<UIOpenURLContext *> *contexts = %orig;
    if (L20IsAllTrails()) for (UIOpenURLContext *context in contexts) L20CaptureURL(context.URL);
    return contexts;
}
%end

%hook UILabel
- (void)setText:(NSString *)text {
    if (L20IsAllTrails() && ([text isEqualToString:@"AllTrails link fix 1.0.18 loaded"] || [text isEqualToString:@"AllTrails link fix 1.0.19 loaded"])) {
        text = @"AllTrails link fix 1.0.20 loaded";
    }
    %orig(text);
}
%end

%end

%ctor {
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    %init(LinkFix20);

    if (!L20IsAllTrails()) return;
    notify_register_dispatch(L20SearchNotify.UTF8String, &L20NotifyToken, dispatch_get_main_queue(), ^(__unused int token) { L20StartDrive(); });
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { L20StartDrive(); }];
    [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { L20StartDrive(); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ L20StartDrive(); });
}