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
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;

    NSString *host = url.host.lowercaseString;
    if (!host.length) return NO;

    return [host isEqualToString:@"alltrails.com"] ||
           [host isEqualToString:@"www.alltrails.com"] ||
           [host hasSuffix:@".alltrails.com"];
}

static NSString *ATTrailSearchName(NSURL *url) {
    if (!ATIsAllTrailsWebURL(url)) return nil;

    NSArray<NSString *> *parts = url.path.pathComponents;
    NSUInteger trailIndex = [parts indexOfObjectPassingTest:^BOOL(NSString *part, NSUInteger idx, BOOL *stop) {
        return [part.lowercaseString isEqualToString:@"trail"];
    }];

    if (trailIndex == NSNotFound || trailIndex + 1 >= parts.count) return nil;

    NSString *slug = parts.lastObject;
    if (!slug.length || [slug.lowercaseString isEqualToString:@"trail"]) return nil;

    NSString *decoded = [slug stringByRemovingPercentEncoding] ?: slug;
    NSString *name = [decoded stringByReplacingOccurrencesOfString:@"-" withString:@" "];

    while ([name containsString:@"  "]) {
        name = [name stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }

    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return name.length ? name : nil;
}

static void ATSetPreference(NSString *key, id value) {
    CFStringRef domain = (__bridge CFStringRef)ATPrefsDomain;
    CFStringRef prefKey = (__bridge CFStringRef)key;

    if (value) {
        CFPreferencesSetAppValue(prefKey, (__bridge CFPropertyListRef)value, domain);
    } else {
        CFPreferencesSetAppValue(prefKey, NULL, domain);
    }
    CFPreferencesAppSynchronize(domain);
}

static id ATCopyPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)ATPrefsDomain);
    return value ? CFBridgingRelease(value) : nil;
}

static void ATStorePendingSearch(NSString *name) {
    if (!name.length) return;
    ATSetPreference(ATPendingNameKey, name);
    ATSetPreference(ATPendingTimeKey, @([[NSDate date] timeIntervalSince1970]));
}

static void ATClearPendingSearch(void) {
    ATSetPreference(ATPendingNameKey, nil);
    ATSetPreference(ATPendingTimeKey, nil);
}

static NSString *ATPendingSearch(void) {
    NSString *name = ATCopyPreference(ATPendingNameKey);
    NSNumber *storedTime = ATCopyPreference(ATPendingTimeKey);

    if (![name isKindOfClass:[NSString class]] || !name.length ||
        ![storedTime isKindOfClass:[NSNumber class]]) {
        return nil;
    }

    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - storedTime.doubleValue;
    if (age < -5.0 || age > 45.0) {
        ATClearPendingSearch();
        return nil;
    }

    return name;
}

static UIWindow *ATMainWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) {
                continue;
            }

            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) return window;
            }
        }

        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window.hidden && window.alpha > 0.0) return window;
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (application.keyWindow) return application.keyWindow;
#pragma clang diagnostic pop

    for (UIWindow *window in application.windows) {
        if (!window.hidden && window.alpha > 0.0) return window;
    }

    return nil;
}

static UIViewController *ATPresentedController(UIViewController *controller) {
    UIViewController *current = controller;

    while (current.presentedViewController &&
           !current.presentedViewController.isBeingDismissed) {
        current = current.presentedViewController;
    }

    return current;
}

static UITabBarController *ATFindTabController(UIViewController *controller) {
    if (!controller) return nil;

    controller = ATPresentedController(controller);

    if ([controller isKindOfClass:[UITabBarController class]]) {
        return (UITabBarController *)controller;
    }

    if ([controller isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)controller;
        UITabBarController *found = ATFindTabController(nav.visibleViewController);
        if (found) return found;
    }

    for (UIViewController *child in controller.childViewControllers) {
        UITabBarController *found = ATFindTabController(child);
        if (found) return found;
    }

    return nil;
}

static BOOL ATStringContainsSearch(NSString *value) {
    if (!value.length) return NO;

    NSString *lower = value.lowercaseString;
    return [lower containsString:@"search"] ||
           [lower containsString:@"explore"] ||
           [lower containsString:@"discover"];
}

static void ATSelectExploreTab(UITabBarController *tabs) {
    if (!tabs || tabs.viewControllers.count == 0) return;

    NSInteger target = -1;

    for (NSUInteger idx = 0; idx < tabs.viewControllers.count; idx++) {
        UIViewController *controller = tabs.viewControllers[idx];
        UITabBarItem *item = controller.tabBarItem;

        if (ATStringContainsSearch(item.title) ||
            ATStringContainsSearch(item.accessibilityLabel)) {
            target = (NSInteger)idx;
            break;
        }
    }

    if (target < 0 && tabs.tabBar.items.count) {
        for (NSUInteger idx = 0; idx < tabs.tabBar.items.count; idx++) {
            UITabBarItem *item = tabs.tabBar.items[idx];
            if (ATStringContainsSearch(item.title) ||
                ATStringContainsSearch(item.accessibilityLabel)) {
                target = (NSInteger)idx;
                break;
            }
        }
    }

    if (target < 0) target = 0;

    if (target < (NSInteger)tabs.viewControllers.count) {
        tabs.selectedIndex = (NSUInteger)target;
    }
}

static UISearchBar *ATFindSearchBarInView(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UISearchBar class]]) return (UISearchBar *)view;

    for (UIView *child in view.subviews) {
        UISearchBar *found = ATFindSearchBarInView(child);
        if (found) return found;
    }

    return nil;
}

static UITextField *ATFindSearchFieldInView(UIView *view) {
    if (!view) return nil;

    if ([view isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)view;

        if (ATStringContainsSearch(field.placeholder) ||
            ATStringContainsSearch(field.accessibilityLabel) ||
            [field.textContentType isEqualToString:UITextContentTypeLocation]) {
            return field;
        }
    }

    for (UIView *child in view.subviews) {
        UITextField *found = ATFindSearchFieldInView(child);
        if (found) return found;
    }

    return nil;
}

static UIControl *ATFindSearchControlInView(UIView *view) {
    if (!view) return nil;

    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)view;
        NSString *title = nil;

        if ([control respondsToSelector:@selector(currentTitle)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            title = [control performSelector:@selector(currentTitle)];
#pragma clang diagnostic pop
        }

        if (ATStringContainsSearch(title) ||
            ATStringContainsSearch(control.accessibilityLabel) ||
            ATStringContainsSearch(control.accessibilityHint)) {
            return control;
        }
    }

    for (UIView *child in view.subviews) {
        UIControl *found = ATFindSearchControlInView(child);
        if (found) return found;
    }

    return nil;
}

static UIViewController *ATVisibleController(UIViewController *controller) {
    if (!controller) return nil;
    controller = ATPresentedController(controller);

    if ([controller isKindOfClass:[UINavigationController class]]) {
        return ATVisibleController(((UINavigationController *)controller).visibleViewController);
    }

    if ([controller isKindOfClass:[UITabBarController class]]) {
        return ATVisibleController(((UITabBarController *)controller).selectedViewController);
    }

    for (UIViewController *child in controller.childViewControllers.reverseObjectEnumerator) {
        if (child.viewIfLoaded.window) return ATVisibleController(child);
    }

    return controller;
}

static UISearchBar *ATSearchBarFromController(UIViewController *controller) {
    UIViewController *current = controller;

    while (current) {
        if (@available(iOS 11.0, *)) {
            UISearchController *searchController = current.navigationItem.searchController;
            if (searchController.searchBar) return searchController.searchBar;
        }

        UISearchBar *bar = ATFindSearchBarInView(current.viewIfLoaded);
        if (bar) return bar;

        current = current.parentViewController;
    }

    return nil;
}

static void ATSubmitSearchBar(UISearchBar *searchBar, NSString *query) {
    if (!searchBar || !query.length) return;

    searchBar.text = query;
    UITextField *field = searchBar.searchTextField;
    field.text = query;

    [field sendActionsForControlEvents:UIControlEventEditingChanged];

    id<UISearchBarDelegate> delegate = searchBar.delegate;
    if ([delegate respondsToSelector:@selector(searchBar:textDidChange:)]) {
        [delegate searchBar:searchBar textDidChange:query];
    }

    [searchBar becomeFirstResponder];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id<UISearchBarDelegate> currentDelegate = searchBar.delegate;
        if ([currentDelegate respondsToSelector:@selector(searchBarSearchButtonClicked:)]) {
            [currentDelegate searchBarSearchButtonClicked:searchBar];
        } else {
            [searchBar.searchTextField sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
        }
    });
}

static void ATSubmitTextField(UITextField *field, NSString *query) {
    if (!field || !query.length) return;

    field.text = query;
    [field sendActionsForControlEvents:UIControlEventEditingChanged];
    [field becomeFirstResponder];

    id<UITextFieldDelegate> delegate = field.delegate;
    BOOL shouldReturn = YES;

    if ([delegate respondsToSelector:@selector(textFieldShouldReturn:)]) {
        shouldReturn = [delegate textFieldShouldReturn:field];
    }

    if (shouldReturn) {
        [field sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
    }
}

static BOOL ATTryPendingSearch(NSUInteger attempt) {
    NSString *query = ATPendingSearch();
    if (!query.length) return YES;

    UIWindow *window = ATMainWindow();
    UIViewController *root = window.rootViewController;
    if (!window || !root) return NO;

    UITabBarController *tabs = ATFindTabController(root);
    ATSelectExploreTab(tabs);

    UIViewController *visible = ATVisibleController(root);
    UISearchBar *searchBar = ATSearchBarFromController(visible);

    if (!searchBar && tabs) {
        searchBar = ATSearchBarFromController(ATVisibleController(tabs.selectedViewController));
    }

    if (searchBar) {
        ATSubmitSearchBar(searchBar, query);
        ATClearPendingSearch();
        return YES;
    }

    UITextField *field = ATFindSearchFieldInView(visible.viewIfLoaded ?: window);
    if (field) {
        ATSubmitTextField(field, query);
        ATClearPendingSearch();
        return YES;
    }

    if (attempt < 5) {
        UIControl *searchControl = ATFindSearchControlInView(visible.viewIfLoaded ?: window);
        if (searchControl) {
            [searchControl sendActionsForControlEvents:UIControlEventTouchUpInside];
        }
    }

    return NO;
}

static void ATStartPendingSearch(void) {
    if (!ATIsAllTrailsProcess() || !ATPendingSearch().length) return;

    __block NSUInteger attempt = 0;
    __block void (^retry)(void) = nil;

    retry = ^{
        if (ATTryPendingSearch(attempt)) {
            retry = nil;
            return;
        }

        attempt++;
        if (attempt >= 10 || !ATPendingSearch().length) {
            retry = nil;
            return;
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), retry);
    };

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), retry);
}

static NSURL *ATBranchHomeURL(NSURL *webURL) {
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"https";
    components.host = @"alltrails.app.link";
    components.path = @"/";

    NSString *fallback = webURL.absoluteString ?: @"https://www.alltrails.com/";
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"$fallback_url" value:fallback],
        [NSURLQueryItem queryItemWithName:@"~feature" value:@"share"],
        [NSURLQueryItem queryItemWithName:@"~channel" value:@"alltrails_virality"]
    ];

    return components.URL ?: webURL;
}

%hook UIApplication

- (void)openURL:(NSURL *)url
        options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey, id> *)options
completionHandler:(void (^)(BOOL success))completion {

    if (ATIsAllTrailsProcess() || !ATIsAllTrailsWebURL(url)) {
        %orig;
        return;
    }

    NSString *trailName = ATTrailSearchName(url);
    if (!trailName.length) {
        NSURL *branchURL = ATBranchHomeURL(url);
        NSMutableDictionary *branchOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
        branchOptions[UIApplicationOpenURLOptionUniversalLinksOnly] = @YES;
        %orig(branchURL, branchOptions, completion);
        return;
    }

    ATStorePendingSearch(trailName);

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

    NSString *trailName = ATTrailSearchName(url);
    if (!trailName.length) {
        return %orig(ATBranchHomeURL(url));
    }

    ATStorePendingSearch(trailName);

    NSURL *launcher = [NSURL URLWithString:@"alltrails://"];
    if (%orig(launcher)) {
        return YES;
    }

    return %orig(ATBranchHomeURL(url));
}

%end

%ctor {
    if (ATIsAllTrailsProcess()) {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            ATStartPendingSearch();
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            ATStartPendingSearch();
        });
    }
}
