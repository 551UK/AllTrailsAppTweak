#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <notify.h>
#include <string.h>

static NSString * const ATAllTrailsBundleID = @"com.alltrails.AllTrails";
static NSString * const ATNotifyPrefix = @"com.551.alltrailsapptweak";
static NSString * const ATSearchNotify = @"com.551.alltrailsapptweak.search";
static NSString * const ATPasteboardName = @"com.551.alltrailsapptweak.handoff";
static const NSUInteger ATMaxPendingBytes = 1024;
static const NSUInteger ATMaxChunks = 128;

static NSURL *ATPendingURL = nil;
static NSString *ATPendingName = nil;
static int ATDarwinToken = 0;
static BOOL ATDidTryInternalRoute = NO;
static BOOL ATInternalRouteWasHandled = NO;
static BOOL ATDidEnterQuery = NO;

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

static NSUInteger ATTrailComponentIndex(NSURL *url) {
    if (!ATIsAllTrailsWebURL(url)) return NSNotFound;
    NSArray<NSString *> *parts = url.path.pathComponents;
    return [parts indexOfObjectPassingTest:^BOOL(NSString *part, NSUInteger idx, BOOL *stop) {
        return [part.lowercaseString isEqualToString:@"trail"];
    }];
}

static NSURL *ATCanonicalTrailURL(NSURL *url) {
    NSUInteger trailIndex = ATTrailComponentIndex(url);
    if (trailIndex == NSNotFound) return nil;

    NSArray<NSString *> *parts = url.path.pathComponents;
    if (trailIndex + 1 >= parts.count) return nil;

    NSMutableString *path = [NSMutableString string];
    for (NSUInteger i = trailIndex; i < parts.count; i++) {
        NSString *part = parts[i];
        if (!part.length || [part isEqualToString:@"/"]) continue;
        [path appendString:@"/"];
        [path appendString:part];
    }

    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"https";
    components.host = @"www.alltrails.com";
    components.path = path;
    components.query = nil;
    components.fragment = nil;
    return components.URL;
}

static NSURL *ATExploreTrailURL(NSURL *canonicalURL) {
    if (!canonicalURL) return nil;
    NSString *path = canonicalURL.path ?: @"";
    if (![path hasPrefix:@"/trail/"]) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:canonicalURL resolvingAgainstBaseURL:NO];
    components.path = [@"/explore" stringByAppendingString:path];
    components.query = nil;
    components.fragment = nil;
    return components.URL;
}

static NSString *ATTrailName(NSURL *url) {
    NSURL *canonicalURL = ATCanonicalTrailURL(url);
    if (!canonicalURL) return nil;

    NSString *slug = canonicalURL.path.pathComponents.lastObject;
    if (!slug.length) return nil;

    NSString *decoded = [slug stringByRemovingPercentEncoding] ?: slug;
    NSString *name = [decoded stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

#pragma mark - Cross-process handoff

static NSString *ATNotifyStateKey(NSString *suffix) {
    return [NSString stringWithFormat:@"%@.%@", ATNotifyPrefix, suffix];
}

static BOOL ATSetNotifyState(NSString *name, uint64_t state) {
    int token = 0;
    if (notify_register_check(name.UTF8String, &token) != 0) return NO;
    int result = notify_set_state(token, state);
    notify_cancel(token);
    return result == 0;
}

static BOOL ATGetNotifyState(NSString *name, uint64_t *state) {
    if (!state) return NO;
    int token = 0;
    if (notify_register_check(name.UTF8String, &token) != 0) return NO;
    int result = notify_get_state(token, state);
    notify_cancel(token);
    return result == 0;
}

static BOOL ATWriteNotifyPayload(NSString *payload) {
    if (!payload.length) return NO;

    NSData *utf8 = [payload dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8.length) return NO;

    NSUInteger length = MIN(utf8.length, ATMaxPendingBytes);
    NSUInteger chunks = (length + 7) / 8;
    if (chunks > ATMaxChunks) return NO;

    const uint8_t *bytes = utf8.bytes;
    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t value = 0;
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, length - offset);
        memcpy(&value, bytes + offset, count);
        if (!ATSetNotifyState(ATNotifyStateKey([NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), value)) {
            return NO;
        }
    }

    uint64_t now = (uint64_t)[[NSDate date] timeIntervalSince1970];
    if (!ATSetNotifyState(ATNotifyStateKey(@"time"), now)) return NO;
    if (!ATSetNotifyState(ATNotifyStateKey(@"length"), (uint64_t)length)) return NO;
    return YES;
}

static NSString *ATReadNotifyPayload(void) {
    uint64_t length64 = 0;
    uint64_t time64 = 0;
    if (!ATGetNotifyState(ATNotifyStateKey(@"length"), &length64)) return nil;
    if (!ATGetNotifyState(ATNotifyStateKey(@"time"), &time64)) return nil;

    NSUInteger length = (NSUInteger)length64;
    if (length == 0 || length > ATMaxPendingBytes) return nil;

    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - (NSTimeInterval)time64;
    if (age < -5.0 || age > 120.0) {
        ATSetNotifyState(ATNotifyStateKey(@"length"), 0);
        return nil;
    }

    NSUInteger chunks = (length + 7) / 8;
    if (chunks > ATMaxChunks) return nil;

    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t value = 0;
        if (!ATGetNotifyState(ATNotifyStateKey([NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), &value)) {
            return nil;
        }
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, length - offset);
        memcpy(bytes + offset, &value, count);
    }

    NSString *payload = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [payload stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void ATWritePasteboardPayload(NSString *payload) {
    if (!payload.length) return;
    UIPasteboard *pasteboard = [UIPasteboard pasteboardWithName:ATPasteboardName create:YES];
    if (!pasteboard) return;

    NSString *wrapped = [NSString stringWithFormat:@"%.0f\n%@",
                         [[NSDate date] timeIntervalSince1970], payload];
    pasteboard.string = wrapped;
}

static NSString *ATReadPasteboardPayload(void) {
    UIPasteboard *pasteboard = [UIPasteboard pasteboardWithName:ATPasteboardName create:NO];
    NSString *wrapped = pasteboard.string;
    if (!wrapped.length) return nil;

    NSRange newline = [wrapped rangeOfString:@"\n"];
    if (newline.location == NSNotFound) return nil;

    NSString *timeString = [wrapped substringToIndex:newline.location];
    NSTimeInterval written = timeString.doubleValue;
    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - written;
    if (written <= 0 || age < -5.0 || age > 120.0) return nil;

    NSString *payload = [wrapped substringFromIndex:newline.location + 1];
    return [payload stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void ATWritePending(NSURL *url) {
    NSURL *canonicalURL = ATCanonicalTrailURL(url);
    if (!canonicalURL) return;

    NSString *payload = canonicalURL.absoluteString;
    ATWriteNotifyPayload(payload);
    ATWritePasteboardPayload(payload);
    notify_post(ATSearchNotify.UTF8String);
}

static NSURL *ATReadPendingURL(void) {
    NSString *payload = ATReadPasteboardPayload();
    if (!payload.length) payload = ATReadNotifyPayload();
    if (!payload.length) return nil;

    NSURL *url = [NSURL URLWithString:payload];
    return ATCanonicalTrailURL(url);
}

static void ATAdoptPending(void) {
    NSURL *url = ATReadPendingURL();
    if (!url) return;

    NSString *name = ATTrailName(url);
    if (!name.length) return;

    if (![ATPendingURL.absoluteString isEqualToString:url.absoluteString]) {
        ATDidTryInternalRoute = NO;
        ATInternalRouteWasHandled = NO;
        ATDidEnterQuery = NO;
    }

    ATPendingURL = url;
    ATPendingName = name;
}

static void ATClearPending(void) {
    ATPendingURL = nil;
    ATPendingName = nil;
    ATDidTryInternalRoute = NO;
    ATInternalRouteWasHandled = NO;
    ATDidEnterQuery = NO;

    if (ATIsAllTrailsProcess()) {
        ATSetNotifyState(ATNotifyStateKey(@"length"), 0);
        UIPasteboard *pasteboard = [UIPasteboard pasteboardWithName:ATPasteboardName create:NO];
        if (pasteboard) pasteboard.string = @"";
    }
}

static BOOL ATLaunchAllTrailsWithoutURL(void) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSelector]) return NO;

    id workspace = ((id (*)(id, SEL))objc_msgSend)((id)workspaceClass, defaultSelector);
    SEL openSelector = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (!workspace || ![workspace respondsToSelector:openSelector]) return NO;

    return ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSelector, ATAllTrailsBundleID);
}

#pragma mark - Synthetic universal-link delivery

static BOOL ATDeliverUserActivityURL(NSURL *url) {
    if (!url || !ATIsAllTrailsProcess()) return NO;

    NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = url;

    UIApplication *app = UIApplication.sharedApplication;
    BOOL handled = NO;

    if (@available(iOS 13.0, *)) {
        SEL sceneSelector = NSSelectorFromString(@"scene:continueUserActivity:");
        for (UIScene *scene in app.connectedScenes) {
            id delegate = scene.delegate;
            if (delegate && [delegate respondsToSelector:sceneSelector]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sceneSelector, scene, activity);
                handled = YES;
            }
        }
    }

    if (!handled) {
        id delegate = app.delegate;
        SEL appSelector = NSSelectorFromString(@"application:continueUserActivity:restorationHandler:");
        if (delegate && [delegate respondsToSelector:appSelector]) {
            void (^restorationHandler)(NSArray *) = ^(__unused NSArray *objects) {};
            handled = ((BOOL (*)(id, SEL, id, id, id))objc_msgSend)(
                delegate, appSelector, app, activity, restorationHandler
            );
        }
    }

    return handled;
}

static BOOL ATTryInternalRoute(void) {
    if (!ATPendingURL || ATDidTryInternalRoute) return ATInternalRouteWasHandled;

    ATDidTryInternalRoute = YES;
    ATInternalRouteWasHandled = ATDeliverUserActivityURL(ATPendingURL);

    if (!ATInternalRouteWasHandled) {
        NSURL *exploreURL = ATExploreTrailURL(ATPendingURL);
        if (exploreURL) {
            ATInternalRouteWasHandled = ATDeliverUserActivityURL(exploreURL);
        }
    }

    return ATInternalRouteWasHandled;
}

#pragma mark - UI helpers

static UIWindow *ATWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) return window;
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (app.keyWindow) return app.keyWindow;
    for (UIWindow *window in app.windows) {
        if (!window.hidden && window.alpha > 0.0) return window;
    }
#pragma clang diagnostic pop

    return nil;
}

static BOOL ATTextContains(NSString *text, NSString *needle) {
    if (!text.length || !needle.length) return NO;
    return [text rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL ATLooksLikeSearch(NSString *text) {
    return ATTextContains(text, @"search") ||
           ATTextContains(text, @"find a trail") ||
           ATTextContains(text, @"find trails") ||
           ATTextContains(text, @"find cities") ||
           ATTextContains(text, @"find city") ||
           ATTextContains(text, @"find places") ||
           ATTextContains(text, @"city or park") ||
           ATTextContains(text, @"trail or park") ||
           ATTextContains(text, @"city, park") ||
           ATTextContains(text, @"park, or trail");
}

static BOOL ATLooksLikeExploreTab(NSString *text) {
    return ATTextContains(text, @"explore") ||
           ATTextContains(text, @"discover") ||
           ATLooksLikeSearch(text);
}

static BOOL ATViewVisible(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.05 || !view.window) return NO;
    CGRect rect = [view convertRect:view.bounds toView:nil];
    return CGRectGetWidth(rect) > 12.0 && CGRectGetHeight(rect) > 8.0;
}

static NSString *ATObjectText(id object) {
    if (!object) return nil;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    if ([object isKindOfClass:[UILabel class]]) {
        NSString *text = ((UILabel *)object).text;
        if (text.length) [parts addObject:text];
    } else if ([object isKindOfClass:[UIButton class]]) {
        NSString *text = ((UIButton *)object).currentTitle;
        if (text.length) [parts addObject:text];
    } else if ([object isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)object;
        if (field.placeholder.length) [parts addObject:field.placeholder];
        if (field.text.length) [parts addObject:field.text];
    } else if ([object isKindOfClass:[UITextView class]]) {
        NSString *text = ((UITextView *)object).text;
        if (text.length) [parts addObject:text];
    }

    if ([object respondsToSelector:@selector(accessibilityLabel)]) {
        NSString *text = [object accessibilityLabel];
        if (text.length) [parts addObject:text];
    }
    if ([object respondsToSelector:@selector(accessibilityHint)]) {
        NSString *text = [object accessibilityHint];
        if (text.length) [parts addObject:text];
    }
    if ([object respondsToSelector:@selector(accessibilityValue)]) {
        NSString *text = [object accessibilityValue];
        if ([text isKindOfClass:[NSString class]] && text.length) [parts addObject:text];
    }

    return parts.count ? [parts componentsJoinedByString:@" "] : nil;
}

static BOOL ATTextLooksLikeFailure(NSString *text) {
    return ATTextContains(text, @"unavailable") ||
           ATTextContains(text, @"not available") ||
           ATTextContains(text, @"not found") ||
           ATTextContains(text, @"can't open") ||
           ATTextContains(text, @"cannot open") ||
           ATTextContains(text, @"unsupported link") ||
           ATTextContains(text, @"link isn't supported") ||
           ATTextContains(text, @"link is not supported");
}

static BOOL ATViewTreeContainsFailure(UIView *view) {
    if (!view) return NO;
    if (ATTextLooksLikeFailure(ATObjectText(view))) return YES;
    for (UIView *subview in view.subviews) {
        if (ATViewTreeContainsFailure(subview)) return YES;
    }
    return NO;
}

static UIButton *ATFindDismissButton(UIView *view) {
    if (!view) return nil;

    if ([view isKindOfClass:[UIButton class]] && ATViewVisible(view)) {
        UIButton *button = (UIButton *)view;
        NSString *title = ATObjectText(button);
        if (ATTextContains(title, @"got it") ||
            [title.lowercaseString isEqualToString:@"ok"] ||
            ATTextContains(title, @"dismiss") ||
            ATTextContains(title, @"close") ||
            ATTextContains(title, @"cancel")) {
            return button;
        }
    }

    for (UIView *subview in view.subviews) {
        UIButton *button = ATFindDismissButton(subview);
        if (button) return button;
    }
    return nil;
}

static UISearchBar *ATFindSearchBar(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UISearchBar class]] && ATViewVisible(view)) return (UISearchBar *)view;

    for (UIView *subview in view.subviews) {
        UISearchBar *bar = ATFindSearchBar(subview);
        if (bar) return bar;
    }
    return nil;
}

static NSInteger ATSearchFieldScore(UITextField *field) {
    if (!field || !ATViewVisible(field) || !field.enabled || !field.userInteractionEnabled) return -1;

    NSInteger score = 0;
    if (ATLooksLikeSearch(field.placeholder)) score += 160;
    if (ATLooksLikeSearch(field.accessibilityLabel)) score += 140;
    if (ATLooksLikeSearch(field.accessibilityHint)) score += 120;
    if (field.returnKeyType == UIReturnKeySearch) score += 80;
    if (ATTextContains(NSStringFromClass(field.class), @"search")) score += 60;
    if (CGRectGetWidth(field.bounds) > 160.0) score += 10;
    return score;
}

static void ATFindBestSearchField(UIView *view, UITextField **best, NSInteger *bestScore) {
    if (!view) return;

    if ([view isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)view;
        NSInteger score = ATSearchFieldScore(field);
        if (score > *bestScore) {
            *best = field;
            *bestScore = score;
        }
    }

    for (UIView *subview in view.subviews) {
        ATFindBestSearchField(subview, best, bestScore);
    }
}

static UITextField *ATFindSearchField(UIView *view) {
    UITextField *best = nil;
    NSInteger bestScore = 39;
    ATFindBestSearchField(view, &best, &bestScore);
    return best;
}

static UIResponder *ATFindFirstResponder(UIView *view) {
    if (!view) return nil;
    if (view.isFirstResponder) return view;

    for (UIView *subview in view.subviews) {
        UIResponder *responder = ATFindFirstResponder(subview);
        if (responder) return responder;
    }
    return nil;
}

static UIControl *ATFindSearchControl(UIView *view) {
    if (!view) return nil;

    if ([view isKindOfClass:[UIControl class]] && ATViewVisible(view)) {
        UIControl *control = (UIControl *)view;
        if (ATLooksLikeSearch(ATObjectText(control))) {
            return control;
        }
    }

    if ([view isKindOfClass:[UILabel class]] && ATLooksLikeSearch(((UILabel *)view).text)) {
        UIView *parent = view.superview;
        for (NSUInteger depth = 0; parent && depth < 6; depth++, parent = parent.superview) {
            if ([parent isKindOfClass:[UIControl class]] && ATViewVisible(parent)) {
                return (UIControl *)parent;
            }
        }
    }

    for (UIView *subview in view.subviews) {
        UIControl *control = ATFindSearchControl(subview);
        if (control) return control;
    }
    return nil;
}

static NSArray *ATAccessibilityChildren(id object) {
    if (!object) return @[];

    NSMutableArray *children = [NSMutableArray array];

    if ([object isKindOfClass:[UIView class]]) {
        [children addObjectsFromArray:((UIView *)object).subviews];
    }

    @try {
        id explicitElements = [object valueForKey:@"accessibilityElements"];
        if ([explicitElements isKindOfClass:[NSArray class]]) {
            [children addObjectsFromArray:explicitElements];
        }
    } @catch (__unused NSException *exception) {}

    SEL countSelector = NSSelectorFromString(@"accessibilityElementCount");
    SEL elementSelector = NSSelectorFromString(@"accessibilityElementAtIndex:");
    if ([object respondsToSelector:countSelector] && [object respondsToSelector:elementSelector]) {
        NSInteger count = ((NSInteger (*)(id, SEL))objc_msgSend)(object, countSelector);
        if (count > 0 && count < 200) {
            for (NSInteger i = 0; i < count; i++) {
                id child = ((id (*)(id, SEL, NSInteger))objc_msgSend)(object, elementSelector, i);
                if (child) [children addObject:child];
            }
        }
    }

    return children;
}

static id ATFindSearchAccessibilityObjectRecursive(id object, NSMutableSet<NSValue *> *visited, NSUInteger depth) {
    if (!object || depth > 16) return nil;

    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)(object)];
    if ([visited containsObject:key]) return nil;
    [visited addObject:key];

    if (![object isKindOfClass:[UITextField class]] &&
        ![object isKindOfClass:[UISearchBar class]] &&
        ATLooksLikeSearch(ATObjectText(object)) &&
        [object respondsToSelector:NSSelectorFromString(@"accessibilityActivate")]) {
        return object;
    }

    for (id child in ATAccessibilityChildren(object)) {
        id match = ATFindSearchAccessibilityObjectRecursive(child, visited, depth + 1);
        if (match) return match;
    }
    return nil;
}

static id ATFindSearchAccessibilityObject(id root) {
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    return ATFindSearchAccessibilityObjectRecursive(root, visited, 0);
}

static BOOL ATActivateObject(id object) {
    if (!object) return NO;

    if ([object isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)object;
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }

    SEL activate = NSSelectorFromString(@"accessibilityActivate");
    if ([object respondsToSelector:activate]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, activate);
    }

    return NO;
}

static UITabBarController *ATFindTabs(UIViewController *controller) {
    if (!controller) return nil;

    if ([controller isKindOfClass:[UITabBarController class]]) {
        return (UITabBarController *)controller;
    }

    if (controller.presentedViewController) {
        UITabBarController *tabs = ATFindTabs(controller.presentedViewController);
        if (tabs) return tabs;
    }

    if ([controller isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)controller;
        UITabBarController *tabs = ATFindTabs(nav.visibleViewController);
        if (tabs) return tabs;
    }

    for (UIViewController *child in controller.childViewControllers) {
        UITabBarController *tabs = ATFindTabs(child);
        if (tabs) return tabs;
    }
    return nil;
}

static void ATSelectExplore(UITabBarController *tabs) {
    if (!tabs || !tabs.viewControllers.count) return;

    NSInteger index = -1;
    for (NSUInteger i = 0; i < tabs.viewControllers.count; i++) {
        UITabBarItem *item = tabs.viewControllers[i].tabBarItem;
        if (ATLooksLikeExploreTab(item.title) || ATLooksLikeExploreTab(item.accessibilityLabel)) {
            index = (NSInteger)i;
            break;
        }
    }

    if (index < 0) index = 0;
    if (index >= (NSInteger)tabs.viewControllers.count) return;

    if (tabs.selectedIndex != (NSUInteger)index) {
        tabs.selectedIndex = (NSUInteger)index;
    }

    UIViewController *selected = tabs.selectedViewController;
    if ([selected isKindOfClass:[UINavigationController class]]) {
        [(UINavigationController *)selected popToRootViewControllerAnimated:NO];
    }
}

static void ATTypeQuery(UITextField *field, NSString *query) {
    if (!field || !query.length) return;

    [field becomeFirstResponder];
    field.text = @"";
    [field sendActionsForControlEvents:UIControlEventEditingChanged];

    if ([field respondsToSelector:@selector(insertText:)]) {
        [field insertText:query];
    }
    if (![field.text isEqualToString:query]) {
        field.text = query;
    }

    [field sendActionsForControlEvents:UIControlEventEditingChanged];
    ATDidEnterQuery = YES;
}

static NSArray<NSString *> *ATSignificantWords(NSString *text) {
    NSString *lower = text.lowercaseString;
    NSCharacterSet *split = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSArray<NSString *> *raw = [lower componentsSeparatedByCharactersInSet:split];

    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *word in raw) {
        if (word.length >= 4) [words addObject:word];
    }
    return words;
}

static NSInteger ATResultScore(NSString *candidate, NSString *query) {
    if (!candidate.length || !query.length) return 0;
    if (ATLooksLikeSearch(candidate)) return 0;

    NSString *candidateLower = candidate.lowercaseString;
    NSString *queryLower = query.lowercaseString;
    if ([candidateLower containsString:queryLower]) return 1000;

    NSArray<NSString *> *words = ATSignificantWords(query);
    NSInteger matched = 0;
    NSInteger score = 0;
    for (NSUInteger i = 0; i < words.count; i++) {
        NSString *word = words[i];
        if ([candidateLower containsString:word]) {
            matched++;
            score += (i < 3 ? 120 : 50);
        }
    }

    NSInteger required = words.count >= 3 ? 3 : (NSInteger)words.count;
    if (required == 0 || matched < required) return 0;
    return score;
}

static void ATFindBestResultObject(id object,
                                   NSString *query,
                                   NSMutableSet<NSValue *> *visited,
                                   NSUInteger depth,
                                   id *best,
                                   NSInteger *bestScore) {
    if (!object || depth > 18) return;

    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)(object)];
    if ([visited containsObject:key]) return;
    [visited addObject:key];

    BOOL isInput = [object isKindOfClass:[UITextField class]] ||
                   [object isKindOfClass:[UISearchBar class]] ||
                   [object isKindOfClass:[UITextView class]];

    if (!isInput) {
        NSInteger score = ATResultScore(ATObjectText(object), query);
        if (score > *bestScore) {
            id activatable = nil;

            if ([object isKindOfClass:[UIControl class]] ||
                [object respondsToSelector:NSSelectorFromString(@"accessibilityActivate")]) {
                activatable = object;
            } else if ([object isKindOfClass:[UIView class]]) {
                UIView *parent = ((UIView *)object).superview;
                for (NSUInteger i = 0; parent && i < 6; i++, parent = parent.superview) {
                    if ([parent isKindOfClass:[UIControl class]]) {
                        activatable = parent;
                        break;
                    }
                }
            }

            if (activatable) {
                *best = activatable;
                *bestScore = score;
            }
        }
    }

    for (id child in ATAccessibilityChildren(object)) {
        ATFindBestResultObject(child, query, visited, depth + 1, best, bestScore);
    }
}

static BOOL ATOpenMatchingResult(NSString *query) {
    UIWindow *window = ATWindow();
    if (!window || !query.length) return NO;

    id best = nil;
    NSInteger bestScore = 0;
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    ATFindBestResultObject(window, query, visited, 0, &best, &bestScore);

    if (!best || bestScore < 300) return NO;
    return ATActivateObject(best);
}

static void ATSubmitBar(UISearchBar *bar, NSString *query) {
    if (!bar || !query.length) return;
    [bar becomeFirstResponder];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UISearchBar *target = ATFindSearchBar(ATWindow()) ?: bar;
        target.text = query;

        UITextField *field = nil;
        if (@available(iOS 13.0, *)) {
            field = target.searchTextField;
        }
        if (field) ATTypeQuery(field, query);

        id<UISearchBarDelegate> delegate = target.delegate;
        if ([delegate respondsToSelector:@selector(searchBar:textDidChange:)]) {
            [delegate searchBar:target textDidChange:query];
        }

        ATDidEnterQuery = YES;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (ATOpenMatchingResult(query)) return;

            id<UISearchBarDelegate> currentDelegate = target.delegate;
            if ([currentDelegate respondsToSelector:@selector(searchBarSearchButtonClicked:)]) {
                [currentDelegate searchBarSearchButtonClicked:target];
            }

            UITextField *currentField = nil;
            if (@available(iOS 13.0, *)) {
                currentField = target.searchTextField;
            }
            [currentField sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
        });
    });
}

static void ATSubmitField(UITextField *field, NSString *query) {
    if (!field || !query.length) return;
    [field becomeFirstResponder];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *window = ATWindow();
        UIResponder *responder = ATFindFirstResponder(window);
        UITextField *target = [responder isKindOfClass:[UITextField class]]
            ? (UITextField *)responder
            : (ATFindSearchField(window) ?: field);

        ATTypeQuery(target, query);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (ATOpenMatchingResult(query)) return;

            id<UITextFieldDelegate> delegate = target.delegate;
            if ([delegate respondsToSelector:@selector(textFieldShouldReturn:)]) {
                [delegate textFieldShouldReturn:target];
            }
            [target sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
        });
    });
}

static BOOL ATTryGenericFirstResponderTyping(NSString *query) {
    UIResponder *responder = ATFindFirstResponder(ATWindow());
    if (!responder || !query.length) return NO;

    SEL insertTextSelector = @selector(insertText:);
    if (![responder respondsToSelector:insertTextSelector]) return NO;

    ((void (*)(id, SEL, id))objc_msgSend)(responder, insertTextSelector, query);
    ATDidEnterQuery = YES;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (ATOpenMatchingResult(query)) return;
        ((void (*)(id, SEL, id))objc_msgSend)(responder, insertTextSelector, @"\n");
    });
    return YES;
}

static BOOL ATExploreSearchIsVisible(UIWindow *window) {
    if (!window) return NO;
    if (ATFindSearchBar(window) || ATFindSearchField(window)) return YES;
    if (ATFindSearchControl(window)) return YES;
    if (ATFindSearchAccessibilityObject(window)) return YES;
    return NO;
}

static BOOL ATTrySearch(NSUInteger attempt) {
    NSString *query = ATPendingName;
    if (!query.length) return YES;

    UIWindow *window = ATWindow();
    if (!window) return NO;

    if (!ATDidTryInternalRoute) {
        ATTryInternalRoute();
        return NO;
    }

    if (ATInternalRouteWasHandled && attempt < 4 &&
        !ATViewTreeContainsFailure(window) &&
        !ATExploreSearchIsVisible(window)) {
        return NO;
    }

    if (ATInternalRouteWasHandled && attempt >= 4 &&
        !ATViewTreeContainsFailure(window) &&
        !ATExploreSearchIsVisible(window)) {
        ATClearPending();
        return YES;
    }

    UIButton *dismiss = ATFindDismissButton(window);
    if (dismiss && ATViewTreeContainsFailure(window)) {
        [dismiss sendActionsForControlEvents:UIControlEventTouchUpInside];
        return NO;
    }

    UITabBarController *tabs = ATFindTabs(window.rootViewController);
    ATSelectExplore(tabs);

    if (ATDidEnterQuery && ATOpenMatchingResult(query)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ATClearPending();
        });
        return YES;
    }

    UISearchBar *bar = ATFindSearchBar(window);
    if (bar) {
        ATSubmitBar(bar, query);
        return NO;
    }

    UITextField *field = ATFindSearchField(window);
    if (field) {
        ATSubmitField(field, query);
        return NO;
    }

    UIControl *control = ATFindSearchControl(window);
    if (control) {
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
        return NO;
    }

    id accessibilitySearch = ATFindSearchAccessibilityObject(window);
    if (accessibilitySearch && ATActivateObject(accessibilitySearch)) {
        return NO;
    }

    if (ATTryGenericFirstResponderTyping(query)) {
        return NO;
    }

    if (ATDidEnterQuery && attempt >= 8) {
        ATClearPending();
        return YES;
    }

    return NO;
}

static void ATRetrySearch(NSUInteger attempt) {
    if (ATTrySearch(attempt)) return;

    if (attempt + 1 >= 36 || !ATPendingName.length) {
        ATClearPending();
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ATRetrySearch(attempt + 1);
    });
}

static void ATStartSearch(void) {
    if (!ATIsAllTrailsProcess() || !ATPendingName.length) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ATRetrySearch(0);
    });
}

#pragma mark - Outgoing AllTrails web links

%hook UIApplication

- (void)openURL:(NSURL *)url
        options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey, id> *)options
completionHandler:(void (^)(BOOL success))completion {

    if (ATIsAllTrailsProcess() || !ATIsAllTrailsWebURL(url) || !ATCanonicalTrailURL(url)) {
        %orig;
        return;
    }

    ATWritePending(url);

    if (ATLaunchAllTrailsWithoutURL()) {
        if (completion) completion(YES);
        return;
    }

    NSURL *launcher = [NSURL URLWithString:@"alltrails://screen/explore"];
    NSMutableDictionary *launchOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
    [launchOptions removeObjectForKey:UIApplicationOpenURLOptionUniversalLinksOnly];
    %orig(launcher, launchOptions, completion);
}

- (BOOL)openURL:(NSURL *)url {
    if (ATIsAllTrailsProcess() || !ATIsAllTrailsWebURL(url) || !ATCanonicalTrailURL(url)) {
        return %orig;
    }

    ATWritePending(url);
    if (ATLaunchAllTrailsWithoutURL()) return YES;

    NSURL *launcher = [NSURL URLWithString:@"alltrails://screen/explore"];
    return %orig(launcher);
}

%end

%ctor {
    if (!ATIsAllTrailsProcess()) return;

    ATAdoptPending();

    notify_register_dispatch(ATSearchNotify.UTF8String,
                             &ATDarwinToken,
                             dispatch_get_main_queue(),
                             ^(__unused int token) {
        ATAdoptPending();
        ATStartSearch();
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ATAdoptPending();
        ATStartSearch();
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
        ATAdoptPending();
        ATStartSearch();
    });
}
