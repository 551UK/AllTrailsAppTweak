#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <notify.h>
#include <string.h>

static NSString * const ATAllTrailsBundleID = @"com.alltrails.AllTrails";
static NSString * const ATNotifyPrefix = @"com.551.alltrailsapptweak";
static NSString * const ATSearchNotify = @"com.551.alltrailsapptweak.search";
static const NSUInteger ATMaxPendingBytes = 240;
static const NSUInteger ATMaxChunks = 30;

static NSString *ATPendingName = nil;
static int ATDarwinToken = 0;

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

static NSString *ATTrailName(NSURL *url) {
    if (!ATIsAllTrailsWebURL(url)) return nil;

    NSArray<NSString *> *parts = url.path.pathComponents;
    NSUInteger trailIndex = [parts indexOfObjectPassingTest:^BOOL(NSString *part, NSUInteger idx, BOOL *stop) {
        return [part.lowercaseString isEqualToString:@"trail"];
    }];
    if (trailIndex == NSNotFound || trailIndex + 1 >= parts.count) return nil;

    NSString *slug = parts.lastObject;
    if (!slug.length) return nil;

    NSString *decoded = [slug stringByRemovingPercentEncoding] ?: slug;
    NSString *name = [decoded stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

#pragma mark - Cross-process handoff

// v1.0.7 used CFPreferences to pass the trail name from the source app to
// AllTrails. Sandboxed apps can end up with different preference containers,
// so AllTrails could launch successfully but never receive the pending search.
// Darwin notify state is owned by notifyd and is visible to both injected
// processes. The trail name is stored in fixed 64-bit state slots and is read
// by AllTrails after launch, so no app-container file sharing is required.

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

static BOOL ATWritePendingIPC(NSString *name) {
    if (!name.length) return NO;

    NSData *utf8 = [name dataUsingEncoding:NSUTF8StringEncoding];
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

    notify_post(ATSearchNotify.UTF8String);
    return YES;
}

static NSString *ATReadPendingIPC(void) {
    uint64_t length64 = 0;
    uint64_t time64 = 0;
    if (!ATGetNotifyState(ATNotifyStateKey(@"length"), &length64)) return nil;
    if (!ATGetNotifyState(ATNotifyStateKey(@"time"), &time64)) return nil;

    NSUInteger length = (NSUInteger)length64;
    if (length == 0 || length > ATMaxPendingBytes) return nil;

    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - (NSTimeInterval)time64;
    if (age < -5.0 || age > 90.0) {
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

    NSString *name = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void ATClearPending(void) {
    ATPendingName = nil;
    if (ATIsAllTrailsProcess()) {
        ATSetNotifyState(ATNotifyStateKey(@"length"), 0);
    }
}

static NSString *ATPending(void) {
    return ATPendingName;
}

static void ATAdoptPendingIPC(void) {
    NSString *name = ATReadPendingIPC();
    if (name.length) ATPendingName = [name copy];
}

// Launch by bundle id so the old AllTrails deep-link router never receives a
// route it cannot understand. The trail name is already waiting in notifyd.
static BOOL ATLaunchAllTrailsWithoutURL(void) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSelector]) return NO;

    id workspace = ((id (*)(id, SEL))objc_msgSend)((id)workspaceClass, defaultSelector);
    SEL openSelector = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (!workspace || ![workspace respondsToSelector:openSelector]) return NO;

    return ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSelector, ATAllTrailsBundleID);
}

#pragma mark - AllTrails UI search

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
           ATTextContains(text, @"explore") ||
           ATTextContains(text, @"discover") ||
           ATTextContains(text, @"find a trail") ||
           ATTextContains(text, @"find trails") ||
           ATTextContains(text, @"find cities") ||
           ATTextContains(text, @"find city") ||
           ATTextContains(text, @"find places") ||
           ATTextContains(text, @"city or park") ||
           ATTextContains(text, @"trail or park");
}

static BOOL ATViewVisible(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.05 || !view.window) return NO;
    return CGRectGetWidth(view.bounds) > 20.0 && CGRectGetHeight(view.bounds) > 10.0;
}

static UIButton *ATFindDismissButton(UIView *view) {
    if (!view) return nil;

    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        NSString *title = button.currentTitle ?: button.accessibilityLabel;
        if (ATTextContains(title, @"got it") ||
            [title.lowercaseString isEqualToString:@"ok"] ||
            ATTextContains(title, @"dismiss") ||
            ATTextContains(title, @"close")) {
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
    if (ATLooksLikeSearch(field.placeholder)) score += 120;
    if (ATLooksLikeSearch(field.accessibilityLabel)) score += 120;
    if (ATLooksLikeSearch(field.accessibilityHint)) score += 100;
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

static UITextField *ATFindFirstResponderField(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UITextField class]] && view.isFirstResponder) {
        return (UITextField *)view;
    }
    for (UIView *subview in view.subviews) {
        UITextField *field = ATFindFirstResponderField(subview);
        if (field) return field;
    }
    return nil;
}

static UIControl *ATFindSearchControl(UIView *view) {
    if (!view) return nil;

    if ([view isKindOfClass:[UIControl class]] && ATViewVisible(view)) {
        UIControl *control = (UIControl *)view;
        NSString *title = nil;
        if ([control isKindOfClass:[UIButton class]]) {
            title = ((UIButton *)control).currentTitle;
        }

        if (ATLooksLikeSearch(control.accessibilityLabel) ||
            ATLooksLikeSearch(control.accessibilityHint) ||
            ATLooksLikeSearch(title)) {
            return control;
        }
    }

    if ([view isKindOfClass:[UILabel class]] && ATLooksLikeSearch(((UILabel *)view).text)) {
        UIView *parent = view.superview;
        for (NSUInteger depth = 0; parent && depth < 5; depth++, parent = parent.superview) {
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
        if (ATLooksLikeSearch(item.title) || ATLooksLikeSearch(item.accessibilityLabel)) {
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
}

static void ATSubmitBar(UISearchBar *bar, NSString *query) {
    [bar becomeFirstResponder];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UISearchBar *target = ATFindSearchBar(ATWindow()) ?: bar;
        target.text = query;
        UITextField *field = target.searchTextField;
        ATTypeQuery(field, query);

        id<UISearchBarDelegate> delegate = target.delegate;
        if ([delegate respondsToSelector:@selector(searchBar:textDidChange:)]) {
            [delegate searchBar:target textDidChange:query];
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id<UISearchBarDelegate> currentDelegate = target.delegate;
            if ([currentDelegate respondsToSelector:@selector(searchBarSearchButtonClicked:)]) {
                [currentDelegate searchBarSearchButtonClicked:target];
            }
            [target.searchTextField sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
        });
    });
}

static void ATSubmitField(UITextField *field, NSString *query) {
    [field becomeFirstResponder];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *window = ATWindow();
        UITextField *target = ATFindFirstResponderField(window) ?: ATFindSearchField(window) ?: field;
        ATTypeQuery(target, query);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            id<UITextFieldDelegate> delegate = target.delegate;
            if ([delegate respondsToSelector:@selector(textFieldShouldReturn:)]) {
                [delegate textFieldShouldReturn:target];
            }
            [target sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
        });
    });
}

static BOOL ATTrySearch(NSUInteger attempt) {
    NSString *query = ATPending();
    if (!query.length) return YES;

    UIWindow *window = ATWindow();
    if (!window) return NO;

    UIButton *dismiss = ATFindDismissButton(window);
    if (dismiss) {
        [dismiss sendActionsForControlEvents:UIControlEventTouchUpInside];
        return NO;
    }

    UITabBarController *tabs = ATFindTabs(window.rootViewController);
    ATSelectExplore(tabs);

    UISearchBar *bar = ATFindSearchBar(window);
    if (bar) {
        ATSubmitBar(bar, query);
        ATClearPending();
        return YES;
    }

    UITextField *field = ATFindSearchField(window);
    if (field) {
        ATSubmitField(field, query);
        ATClearPending();
        return YES;
    }

    UIControl *control = ATFindSearchControl(window);
    if (control) {
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
    }

    return NO;
}

static void ATRetrySearch(NSUInteger attempt) {
    if (ATTrySearch(attempt)) return;
    if (attempt + 1 >= 30 || !ATPending().length) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ATRetrySearch(attempt + 1);
    });
}

static void ATStartSearch(void) {
    if (!ATIsAllTrailsProcess() || !ATPending().length) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ATRetrySearch(0);
    });
}

#pragma mark - Outgoing AllTrails web links

%hook UIApplication

- (void)openURL:(NSURL *)url
        options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey, id> *)options
completionHandler:(void (^)(BOOL success))completion {

    if (ATIsAllTrailsProcess() || !ATIsAllTrailsWebURL(url)) {
        %orig;
        return;
    }

    NSString *name = ATTrailName(url);
    if (!name.length) {
        %orig;
        return;
    }

    ATWritePendingIPC(name);

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
    if (ATIsAllTrailsProcess() || !ATIsAllTrailsWebURL(url)) {
        return %orig;
    }

    NSString *name = ATTrailName(url);
    if (!name.length) return %orig;

    ATWritePendingIPC(name);
    if (ATLaunchAllTrailsWithoutURL()) return YES;

    NSURL *launcher = [NSURL URLWithString:@"alltrails://screen/explore"];
    return %orig(launcher);
}

%end

%ctor {
    if (!ATIsAllTrailsProcess()) return;

    ATAdoptPendingIPC();

    notify_register_dispatch(ATSearchNotify.UTF8String,
                             &ATDarwinToken,
                             dispatch_get_main_queue(),
                             ^(__unused int token) {
        ATAdoptPendingIPC();
        ATStartSearch();
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ATAdoptPendingIPC();
        ATStartSearch();
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
        ATAdoptPendingIPC();
        ATStartSearch();
    });
}
