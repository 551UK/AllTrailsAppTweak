#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString * const ATPrefsDomain = @"com.551.alltrailsapptweak";
static NSString * const ATPendingNameKey = @"PendingTrailSearch";
static NSString * const ATPendingTimeKey = @"PendingTrailSearchTime";

static BOOL ATIsAllTrailsProcess(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.alltrails.AllTrails"];
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
    if (age < -5.0 || age > 45.0) {
        ATClearPending();
        return nil;
    }
    return name;
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
#pragma clang diagnostic pop

    for (UIWindow *window in app.windows) {
        if (!window.hidden && window.alpha > 0.0) return window;
    }
    return nil;
}

static BOOL ATMatchesSearch(NSString *text) {
    NSString *lower = text.lowercaseString;
    if (!lower.length) return NO;
    return [lower containsString:@"search"] ||
           [lower containsString:@"explore"] ||
           [lower containsString:@"discover"] ||
           [lower containsString:@"find a trail"];
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
        if (ATMatchesSearch(field.placeholder) ||
            ATMatchesSearch(field.accessibilityLabel)) {
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
        if (ATMatchesSearch(control.accessibilityLabel) ||
            ATMatchesSearch(control.accessibilityHint)) {
            return control;
        }

        if ([control isKindOfClass:[UIButton class]]) {
            UIButton *button = (UIButton *)control;
            if (ATMatchesSearch(button.currentTitle)) return button;
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

    if (controller.presentedViewController) {
        UITabBarController *tabs = ATFindTabs(controller.presentedViewController);
        if (tabs) return tabs;
    }

    if ([controller isKindOfClass:[UITabBarController class]]) {
        return (UITabBarController *)controller;
    }

    if ([controller isKindOfClass:[UINavigationController class]]) {
        UITabBarController *tabs = ATFindTabs(((UINavigationController *)controller).visibleViewController);
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
        if (ATMatchesSearch(item.title) || ATMatchesSearch(item.accessibilityLabel)) {
            index = (NSInteger)i;
            break;
        }
    }

    if (index < 0) index = 0;
    if (index < (NSInteger)tabs.viewControllers.count) tabs.selectedIndex = (NSUInteger)index;
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
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

    if (attempt < 6) {
        UIControl *control = ATFindSearchControl(window);
        if (control) [control sendActionsForControlEvents:UIControlEventTouchUpInside];
    }

    return NO;
}

static void ATStartSearch(void) {
    if (!ATIsAllTrailsProcess() || !ATPending().length) return;

    __block NSUInteger attempt = 0;
    __block void (^retry)(void);
    retry = ^{
        if (ATTrySearch(attempt)) return;

        attempt++;
        if (attempt >= 12 || !ATPending().length) return;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), retry);
    };

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), retry);
}

static NSURL *ATBranchHomeURL(NSURL *original) {
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"https";
    components.host = @"alltrails.app.link";
    components.path = @"/";
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"$fallback_url"
                                    value:original.absoluteString ?: @"https://www.alltrails.com/"],
        [NSURLQueryItem queryItemWithName:@"~feature" value:@"share"]
    ];
    return components.URL ?: original;
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
        NSURL *branchURL = ATBranchHomeURL(url);
        NSMutableDictionary *branchOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
        branchOptions[UIApplicationOpenURLOptionUniversalLinksOnly] = @YES;
        %orig(branchURL, branchOptions, completion);
        return;
    }

    ATStorePending(name);

    NSURL *launcher = [NSURL URLWithString:@"alltrails://"];
    NSMutableDictionary *launchOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
    [launchOptions removeObjectForKey:UIApplicationOpenURLOptionUniversalLinksOnly];

    [self openURL:launcher
          options:launchOptions
completionHandler:^(BOOL success) {
        if (success) {
            if (completion) completion(YES);
            return;
        }

        NSURL *branchURL = ATBranchHomeURL(url);
        NSMutableDictionary *branchOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
        branchOptions[UIApplicationOpenURLOptionUniversalLinksOnly] = @YES;

        [self openURL:branchURL
              options:branchOptions
    completionHandler:^(BOOL branchSuccess) {
            if (completion) completion(branchSuccess);
        }];
    }];
}

- (BOOL)openURL:(NSURL *)url {
    if (ATIsAllTrailsProcess() || !ATIsAllTrailsWebURL(url)) {
        return %orig;
    }

    NSString *name = ATTrailName(url);
    if (!name.length) {
        NSURL *branchURL = ATBranchHomeURL(url);
        return %orig(branchURL);
    }

    ATStorePending(name);

    NSURL *launcher = [NSURL URLWithString:@"alltrails://"];
    BOOL launched = %orig(launcher);
    if (launched) return YES;

    NSURL *branchURL = ATBranchHomeURL(url);
    return %orig(branchURL);
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
