#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSString * const ATPrefsDomain = @"com.551.alltrailsapptweak";
static NSString * const ATPendingNameKey = @"PendingTrailSearch";
static NSString * const ATPendingTimeKey = @"PendingTrailSearchTime";
static NSString * const ATAllTrailsBundleID = @"com.alltrails.AllTrails";

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

static void ATSetPref(NSString *key, id value) {
    CFStringRef domain = (__bridge CFStringRef)ATPrefsDomain;
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             value ? (__bridge CFPropertyListRef)value : NULL,
                             domain);
    CFPreferencesAppSynchronize(domain);
}

static id ATGetPref(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)ATPrefsDomain);
    return value ? CFBridgingRelease(value) : nil;
}

static void ATStorePending(NSString *name) {
    if (!name.length) return;
    ATSetPref(ATPendingNameKey, name);
    ATSetPref(ATPendingTimeKey, @([[NSDate date] timeIntervalSince1970]));
}

static void ATClearPending(void) {
    ATSetPref(ATPendingNameKey, nil);
    ATSetPref(ATPendingTimeKey, nil);
}

static NSString *ATPending(void) {
    NSString *name = ATGetPref(ATPendingNameKey);
    NSNumber *time = ATGetPref(ATPendingTimeKey);
    if (![name isKindOfClass:[NSString class]] || !name.length ||
        ![time isKindOfClass:[NSNumber class]]) return nil;

    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - time.doubleValue;
    if (age < -5.0 || age > 60.0) {
        ATClearPending();
        return nil;
    }
    return name;
}

// Bare alltrails:// is not a neutral app launcher on the older AllTrails
// build: its legacy router treats the empty route as content and shows
// "Content unavailable". LaunchServices opens the application by bundle ID
// instead, so no deep-link route is handed to AllTrails at all.
static BOOL ATLaunchAllTrailsWithoutURL(void) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSelector]) return NO;

    id workspace = ((id (*)(id, SEL))objc_msgSend)((id)workspaceClass, defaultSelector);
    SEL openSelector = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (!workspace || ![workspace respondsToSelector:openSelector]) return NO;

    return ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSelector, ATAllTrailsBundleID);
}

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
           ATTextContains(text, @"find a trail");
}

static UIButton *ATFindDismissButton(UIView *view) {
    if (!view) return nil;

    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        NSString *title = button.currentTitle ?: button.accessibilityLabel;
        if (ATTextContains(title, @"got it") ||
            [title.lowercaseString isEqualToString:@"ok"] ||
            ATTextContains(title, @"dismiss")) {
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
    if ([view isKindOfClass:[UISearchBar class]]) return (UISearchBar *)view;

    for (UIView *subview in view.subviews) {
        UISearchBar *bar = ATFindSearchBar(subview);
        if (bar) return bar;
    }
    return nil;
}

static UITextField *ATFindSearchField(UIView *view) {
    if (!view) return nil;

    if ([view isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)view;
        if (ATLooksLikeSearch(field.placeholder) || ATLooksLikeSearch(field.accessibilityLabel)) {
            return field;
        }
    }

    for (UIView *subview in view.subviews) {
        UITextField *field = ATFindSearchField(subview);
        if (field) return field;
    }
    return nil;
}

static UIControl *ATFindSearchControl(UIView *view) {
    if (!view) return nil;

    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)view;
        if (ATLooksLikeSearch(control.accessibilityLabel) || ATLooksLikeSearch(control.accessibilityHint)) {
            return control;
        }
        if ([control isKindOfClass:[UIButton class]] && ATLooksLikeSearch(((UIButton *)control).currentTitle)) {
            return control;
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

    tabs.selectedIndex = (NSUInteger)index;

    UIViewController *selected = tabs.selectedViewController;
    if ([selected isKindOfClass:[UINavigationController class]]) {
        [(UINavigationController *)selected popToRootViewControllerAnimated:NO];
    }
}

static void ATSubmitBar(UISearchBar *bar, NSString *query) {
    bar.text = query;
    UITextField *field = bar.searchTextField;
    field.text = query;
    [field sendActionsForControlEvents:UIControlEventEditingChanged];

    id<UISearchBarDelegate> delegate = bar.delegate;
    if ([delegate respondsToSelector:@selector(searchBar:textDidChange:)]) {
        [delegate searchBar:bar textDidChange:query];
    }

    [bar becomeFirstResponder];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id<UISearchBarDelegate> currentDelegate = bar.delegate;
        if ([currentDelegate respondsToSelector:@selector(searchBarSearchButtonClicked:)]) {
            [currentDelegate searchBarSearchButtonClicked:bar];
        } else {
            [bar.searchTextField sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
        }
    });
}

static void ATSubmitField(UITextField *field, NSString *query) {
    field.text = query;
    [field sendActionsForControlEvents:UIControlEventEditingChanged];
    [field becomeFirstResponder];

    id<UITextFieldDelegate> delegate = field.delegate;
    if ([delegate respondsToSelector:@selector(textFieldShouldReturn:)]) {
        [delegate textFieldShouldReturn:field];
    }
    [field sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
}

static BOOL ATTrySearch(NSUInteger attempt) {
    NSString *query = ATPending();
    if (!query.length) return YES;

    UIWindow *window = ATWindow();
    if (!window) return NO;

    // Clear the exact stale error screen produced by the previous builds.
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

    if (attempt < 8) {
        UIControl *control = ATFindSearchControl(window);
        if (control) [control sendActionsForControlEvents:UIControlEventTouchUpInside];
    }

    return NO;
}

static void ATRetrySearch(NSUInteger attempt) {
    if (ATTrySearch(attempt)) return;
    if (attempt + 1 >= 16 || !ATPending().length) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ATRetrySearch(attempt + 1);
    });
}

static void ATStartSearch(void) {
    if (!ATIsAllTrailsProcess() || !ATPending().length) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ATRetrySearch(0);
    });
}

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

    ATStorePending(name);

    if (ATLaunchAllTrailsWithoutURL()) {
        if (completion) completion(YES);
        return;
    }

    // Last-resort fallback if LaunchServices is unavailable.
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

    ATStorePending(name);
    if (ATLaunchAllTrailsWithoutURL()) return YES;

    NSURL *launcher = [NSURL URLWithString:@"alltrails://screen/explore"];
    return %orig(launcher);
}

%end

%ctor {
    if (ATIsAllTrailsProcess()) {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            ATStartSearch();
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            ATStartSearch();
        });
    }
}
