#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString * const ATFBundleID = @"com.alltrails.AllTrails";
static NSString *ATFPendingName = nil;
static NSString *ATFLastURL = nil;
static NSTimeInterval ATFLastTime = 0;
static NSUInteger ATFGeneration = 0;
static BOOL ATFDriving = NO;
static BOOL ATFDidShowCaptureToast = NO;
static NSMutableDictionary<NSString *, NSValue *> *ATFOriginalIMPs = nil;
static NSMutableSet<NSString *> *ATFHooked = nil;

static BOOL ATFIsAllTrails(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    return [bundleID isEqualToString:ATFBundleID] ||
           [bundleID caseInsensitiveCompare:@"com.alltrails.alltrails"] == NSOrderedSame;
}

static BOOL ATFIsWebURL(NSURL *url) {
    if (!url) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    NSString *host = url.host.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    return [host isEqualToString:@"alltrails.com"] ||
           [host isEqualToString:@"www.alltrails.com"] ||
           [host hasSuffix:@".alltrails.com"];
}

static NSString *ATFTrailName(NSURL *url) {
    if (!ATFIsWebURL(url)) return nil;
    NSArray<NSString *> *raw = [url.path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in raw) if (part.length) [parts addObject:part];

    BOOL foundTrail = NO;
    for (NSString *part in parts) {
        if ([part.lowercaseString isEqualToString:@"trail"]) {
            foundTrail = YES;
            break;
        }
    }
    if (!foundTrail || parts.count < 2) return nil;

    NSString *slug = parts.lastObject;
    NSString *decoded = [slug stringByRemovingPercentEncoding] ?: slug;
    NSString *name = [decoded stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    name = [name stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    while ([name containsString:@"  "]) name = [name stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static UIWindow *ATFWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
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

static BOOL ATFVisible(UIView *view) {
    if (!view || !view.window || view.hidden || view.alpha < 0.05) return NO;
    CGRect rect = [view convertRect:view.bounds toView:nil];
    return CGRectGetWidth(rect) > 4.0 && CGRectGetHeight(rect) > 4.0;
}

static NSString *ATFText(id object) {
    if (!object) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if ([object isKindOfClass:[UILabel class]] && ((UILabel *)object).text.length) [parts addObject:((UILabel *)object).text];
    if ([object isKindOfClass:[UIButton class]] && ((UIButton *)object).currentTitle.length) [parts addObject:((UIButton *)object).currentTitle];
    if ([object isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)object;
        if (field.placeholder.length) [parts addObject:field.placeholder];
        if (field.text.length) [parts addObject:field.text];
    }
    if ([object isKindOfClass:[UISearchBar class]]) {
        UISearchBar *bar = (UISearchBar *)object;
        if (bar.placeholder.length) [parts addObject:bar.placeholder];
        if (bar.text.length) [parts addObject:bar.text];
    }
    if ([object respondsToSelector:@selector(accessibilityLabel)]) {
        NSString *text = [object accessibilityLabel];
        if (text.length) [parts addObject:text];
    }
    if ([object respondsToSelector:@selector(accessibilityValue)]) {
        NSString *text = [object accessibilityValue];
        if (text.length) [parts addObject:text];
    }
    if ([object respondsToSelector:@selector(accessibilityIdentifier)]) {
        NSString *text = [object accessibilityIdentifier];
        if (text.length) [parts addObject:text];
    }
    return parts.count ? [parts componentsJoinedByString:@" "] : nil;
}

static NSString *ATFNormalize(NSString *text) {
    if (!text.length) return @"";
    NSString *lower = [[text stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:[NSLocale currentLocale]] lowercaseString];
    NSMutableString *result = [NSMutableString string];
    BOOL lastSpace = NO;
    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [result appendFormat:@"%C", c];
            lastSpace = NO;
        } else if (!lastSpace && result.length) {
            [result appendString:@" "];
            lastSpace = YES;
        }
    }
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

static BOOL ATFContains(NSString *text, NSArray<NSString *> *needles) {
    NSString *lower = text.lowercaseString;
    if (!lower.length) return NO;
    for (NSString *needle in needles) if ([lower rangeOfString:needle.lowercaseString].location != NSNotFound) return YES;
    return NO;
}

static UIView *ATFFindView(UIView *root, BOOL (^predicate)(UIView *)) {
    if (!root || !predicate) return nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (ATFVisible(view) && predicate(view)) return view;
        for (UIView *child in view.subviews.reverseObjectEnumerator) [stack addObject:child];
    }
    return nil;
}

static UIViewController *ATFFindController(UIViewController *root, Class cls) {
    if (!root) return nil;
    if ([root isKindOfClass:cls]) return root;
    if (root.presentedViewController) {
        UIViewController *found = ATFFindController(root.presentedViewController, cls);
        if (found) return found;
    }
    if ([root isKindOfClass:[UINavigationController class]]) {
        UIViewController *found = ATFFindController(((UINavigationController *)root).visibleViewController, cls);
        if (found) return found;
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in ((UITabBarController *)root).viewControllers) {
            UIViewController *found = ATFFindController(child, cls);
            if (found) return found;
        }
    }
    for (UIViewController *child in root.childViewControllers) {
        UIViewController *found = ATFFindController(child, cls);
        if (found) return found;
    }
    return nil;
}

static BOOL ATFActivate(UIView *view) {
    if (!view) return NO;
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if ([candidate isKindOfClass:[UIControl class]]) {
            [(UIControl *)candidate sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        if ([candidate isKindOfClass:[UITableViewCell class]]) {
            UIView *parent = candidate.superview;
            while (parent && ![parent isKindOfClass:[UITableView class]]) parent = parent.superview;
            UITableView *table = [parent isKindOfClass:[UITableView class]] ? (UITableView *)parent : nil;
            NSIndexPath *indexPath = table ? [table indexPathForCell:(UITableViewCell *)candidate] : nil;
            if (indexPath && [table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                [table.delegate tableView:table didSelectRowAtIndexPath:indexPath];
                return YES;
            }
        }
        if ([candidate isKindOfClass:[UICollectionViewCell class]]) {
            UIView *parent = candidate.superview;
            while (parent && ![parent isKindOfClass:[UICollectionView class]]) parent = parent.superview;
            UICollectionView *collection = [parent isKindOfClass:[UICollectionView class]] ? (UICollectionView *)parent : nil;
            NSIndexPath *indexPath = collection ? [collection indexPathForCell:(UICollectionViewCell *)candidate] : nil;
            if (indexPath && [collection.delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                [collection.delegate collectionView:collection didSelectItemAtIndexPath:indexPath];
                return YES;
            }
        }
        if ([candidate respondsToSelector:@selector(accessibilityActivate)] && [candidate accessibilityActivate]) return YES;
    }
    return NO;
}

static UIView *ATFFirstResponder(UIView *root) {
    if (!root) return nil;
    if (root.isFirstResponder) return root;
    for (UIView *child in root.subviews) {
        UIView *found = ATFFirstResponder(child);
        if (found) return found;
    }
    return nil;
}

static UITextField *ATFSearchField(UIWindow *window) {
    __block UITextField *best = nil;
    __block NSInteger bestScore = NSIntegerMin;
    CGFloat height = CGRectGetHeight(window.bounds);
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        for (UIView *child in view.subviews.reverseObjectEnumerator) [stack addObject:child];
        if (![view isKindOfClass:[UITextField class]] || !ATFVisible(view)) continue;
        UITextField *field = (UITextField *)view;
        NSString *text = ATFText(field) ?: @"";
        NSString *className = NSStringFromClass(field.class).lowercaseString;
        NSInteger score = 0;
        if (ATFContains(text, @[@"find parks", @"find park", @"search", @"trail", @"city", @"park", @"place", @"location"])) score += 160;
        if ([className containsString:@"search"] || [className containsString:@"query"]) score += 120;
        CGRect rect = [field convertRect:field.bounds toView:window];
        if (CGRectGetMidY(rect) < height * 0.42) score += 45;
        if (field.isFirstResponder) score += 80;
        if (field.secureTextEntry) score -= 300;
        if (score > bestScore) { bestScore = score; best = field; }
    }
    return bestScore >= 40 ? best : nil;
}

static UISearchBar *ATFSearchBar(UIWindow *window) {
    return (UISearchBar *)ATFFindView(window, ^BOOL(UIView *view) { return [view isKindOfClass:[UISearchBar class]]; });
}

static void ATFSubmitField(UITextField *field, NSString *query) {
    if (!field || !query.length) return;
    [field becomeFirstResponder];
    field.text = @"";
    [field sendActionsForControlEvents:UIControlEventEditingChanged];
    [field insertText:query];
    field.text = query;
    [field sendActionsForControlEvents:UIControlEventEditingChanged];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([field.delegate respondsToSelector:@selector(textFieldShouldReturn:)]) [field.delegate textFieldShouldReturn:field];
        [field sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
        [[UIApplication sharedApplication] sendAction:NSSelectorFromString(@"insertNewline:") to:nil from:nil forEvent:nil];
    });
}

static void ATFSubmitBar(UISearchBar *bar, NSString *query) {
    if (!bar || !query.length) return;
    [bar becomeFirstResponder];
    bar.text = query;
    if (@available(iOS 13.0, *)) {
        UITextField *field = bar.searchTextField;
        field.text = @"";
        [field sendActionsForControlEvents:UIControlEventEditingChanged];
        [field insertText:query];
        field.text = query;
        [field sendActionsForControlEvents:UIControlEventEditingChanged];
    }
    if ([bar.delegate respondsToSelector:@selector(searchBar:textDidChange:)]) [bar.delegate searchBar:bar textDidChange:query];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([bar.delegate respondsToSelector:@selector(searchBarSearchButtonClicked:)]) [bar.delegate searchBarSearchButtonClicked:bar];
        [[UIApplication sharedApplication] sendAction:NSSelectorFromString(@"insertNewline:") to:nil from:nil forEvent:nil];
    });
}

static BOOL ATFSubmitResponder(UIWindow *window, NSString *query) {
    UIView *responder = ATFFirstResponder(window);
    if ([responder isKindOfClass:[UITextField class]]) {
        ATFSubmitField((UITextField *)responder, query);
        return YES;
    }
    if ([responder conformsToProtocol:@protocol(UIKeyInput)]) {
        id<UIKeyInput> input = (id<UIKeyInput>)responder;
        for (NSUInteger i = 0; i < 160 && [input hasText]; i++) [input deleteBackward];
        [input insertText:query];
        [[UIApplication sharedApplication] sendAction:NSSelectorFromString(@"insertNewline:") to:nil from:nil forEvent:nil];
        return YES;
    }
    return NO;
}

static BOOL ATFSelectExplore(UIWindow *window) {
    UITabBarController *tabs = (UITabBarController *)ATFFindController(window.rootViewController, [UITabBarController class]);
    if (tabs && tabs.viewControllers.count) {
        for (NSUInteger i = 0; i < tabs.viewControllers.count; i++) {
            UIViewController *controller = tabs.viewControllers[i];
            NSString *title = controller.tabBarItem.title ?: controller.title ?: controller.tabBarItem.accessibilityLabel;
            if (ATFContains(title, @[@"explore", @"discover", @"search"])) {
                tabs.selectedIndex = i;
                return YES;
            }
        }
        tabs.selectedIndex = 0;
        return YES;
    }
    UIView *explore = ATFFindView(window, ^BOOL(UIView *view) { return ATFContains(ATFText(view), @[@"explore", @"discover"]); });
    return explore ? ATFActivate(explore) : NO;
}

static BOOL ATFActivateSearch(UIWindow *window) {
    UIView *search = ATFFindView(window, ^BOOL(UIView *view) {
        return ATFContains(ATFText(view), @[@"find parks", @"find park", @"find a trail", @"find trails", @"search", @"where do you want to go"]);
    });
    if (search && ATFActivate(search)) return YES;
    CGFloat safeTop = window.safeAreaInsets.top;
    for (NSNumber *offset in @[@72.0, @92.0, @108.0, @126.0]) {
        CGPoint point = CGPointMake(CGRectGetMidX(window.bounds), safeTop + offset.doubleValue);
        UIView *hit = [window hitTest:point withEvent:nil];
        if (hit && ATFActivate(hit)) return YES;
    }
    return NO;
}

static BOOL ATFMatches(NSString *candidateText, NSString *query) {
    NSString *candidate = ATFNormalize(candidateText);
    NSString *wanted = ATFNormalize(query);
    if (!candidate.length || !wanted.length) return NO;
    if ([candidate rangeOfString:wanted].location != NSNotFound) return YES;

    NSSet<NSString *> *ignored = [NSSet setWithObjects:@"and", @"the", @"via", @"trail", @"circular", @"loop", nil];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *token in [wanted componentsSeparatedByString:@" "]) if (token.length >= 3 && ![ignored containsObject:token]) [tokens addObject:token];
    if (tokens.count < 2) return NO;
    NSUInteger matched = 0;
    for (NSString *token in tokens) if ([candidate rangeOfString:token].location != NSNotFound) matched++;
    return matched >= MAX((NSUInteger)2, (tokens.count + 1) / 2);
}

static BOOL ATFOpenResult(UIWindow *window, NSString *query) {
    UIView *match = ATFFindView(window, ^BOOL(UIView *view) {
        if ([view isKindOfClass:[UITextField class]] || [view isKindOfClass:[UISearchBar class]]) return NO;
        return ATFMatches(ATFText(view), query);
    });
    return match ? ATFActivate(match) : NO;
}

static void ATFToast(NSString *text) {
    UIWindow *window = ATFWindow();
    if (!window) return;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.90];
    label.layer.cornerRadius = 10.0;
    label.layer.masksToBounds = YES;
    CGFloat width = MIN(CGRectGetWidth(window.bounds) - 32.0, 310.0);
    label.frame = CGRectMake((CGRectGetWidth(window.bounds) - width) * 0.5, window.safeAreaInsets.top + 8.0, width, 34.0);
    [window addSubview:label];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [label removeFromSuperview]; });
}

static void ATFDrive(NSUInteger generation, NSUInteger attempt);
static void ATFSchedule(NSUInteger generation, NSUInteger attempt, NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ATFDrive(generation, attempt); });
}

static void ATFDrive(NSUInteger generation, NSUInteger attempt) {
    if (generation != ATFGeneration || !ATFPendingName.length) { ATFDriving = NO; return; }
    if (attempt >= 80) { ATFDriving = NO; return; }
    UIWindow *window = ATFWindow();
    if (!window) { ATFSchedule(generation, attempt + 1, 0.30); return; }

    if (!ATFDidShowCaptureToast) {
        ATFDidShowCaptureToast = YES;
        ATFToast(@"AllTrails link captured — searching…");
    }

    if (ATFOpenResult(window, ATFPendingName)) {
        ATFPendingName = nil;
        ATFDriving = NO;
        return;
    }

    UISearchBar *bar = ATFSearchBar(window);
    if (bar) {
        if (![ATFNormalize(bar.text) isEqualToString:ATFNormalize(ATFPendingName)]) ATFSubmitBar(bar, ATFPendingName);
        ATFSchedule(generation, attempt + 1, 0.55);
        return;
    }

    UITextField *field = ATFSearchField(window);
    if (field) {
        if (![ATFNormalize(field.text) isEqualToString:ATFNormalize(ATFPendingName)]) ATFSubmitField(field, ATFPendingName);
        ATFSchedule(generation, attempt + 1, 0.55);
        return;
    }

    if (ATFSubmitResponder(window, ATFPendingName)) {
        ATFSchedule(generation, attempt + 1, 0.55);
        return;
    }

    if (attempt < 5 || attempt % 12 == 0) ATFSelectExplore(window);
    else ATFActivateSearch(window);
    ATFSchedule(generation, attempt + 1, 0.35);
}

static void ATFStartDrive(void) {
    if (!ATFIsAllTrails() || !ATFPendingName.length || ATFDriving) return;
    ATFDriving = YES;
    ATFSchedule(ATFGeneration, 0, 0.12);
}

static void ATFCaptureURL(NSURL *url) {
    if (!ATFIsAllTrails()) return;
    NSString *name = ATFTrailName(url);
    if (!name.length) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *absolute = url.absoluteString ?: @"";
    if ([ATFLastURL isEqualToString:absolute] && (now - ATFLastTime) < 2.0) return;
    ATFLastURL = [absolute copy];
    ATFLastTime = now;
    ATFPendingName = [name copy];
    ATFGeneration++;
    ATFDriving = NO;
    ATFDidShowCaptureToast = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ ATFStartDrive(); });
}

static void ATFCaptureActivity(NSUserActivity *activity) {
    if (!activity) return;
    ATFCaptureURL(activity.webpageURL);
    for (id value in activity.userInfo.allValues) {
        if ([value isKindOfClass:[NSURL class]]) ATFCaptureURL(value);
        else if ([value isKindOfClass:[NSString class]] && [(NSString *)value rangeOfString:@"alltrails.com" options:NSCaseInsensitiveSearch].location != NSNotFound) ATFCaptureURL([NSURL URLWithString:value]);
    }
}

static NSString *ATFHookKey(Class cls, SEL sel) { return [NSString stringWithFormat:@"%p|%@", cls, NSStringFromSelector(sel)]; }
static IMP ATFOriginal(id object, SEL sel) {
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        NSValue *boxed = ATFOriginalIMPs[ATFHookKey(cls, sel)];
        if (boxed) { IMP imp = NULL; [boxed getValue:&imp]; return imp; }
    }
    return NULL;
}

static void ATFHook(Class cls, SEL sel, IMP replacement, const char *fallbackTypes) {
    if (!cls || !sel || !replacement) return;
    NSString *key = ATFHookKey(cls, sel);
    if ([ATFHooked containsObject:key]) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        if (fallbackTypes && class_addMethod(cls, sel, replacement, fallbackTypes)) [ATFHooked addObject:key];
        return;
    }
    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method) ?: fallbackTypes;
    if (!original || !types || original == replacement) return;
    class_addMethod(cls, sel, original, types);
    Method target = class_getInstanceMethod(cls, sel);
    if (!target) return;
    ATFOriginalIMPs[key] = [NSValue value:&original withObjCType:@encode(IMP)];
    method_setImplementation(target, replacement);
    [ATFHooked addObject:key];
}

typedef BOOL (*ATFAppContinueIMP)(id, SEL, UIApplication *, NSUserActivity *, void (^)(NSArray *));
typedef BOOL (*ATFAppFinishIMP)(id, SEL, UIApplication *, NSDictionary *);
typedef void (*ATFSceneContinueIMP)(id, SEL, UIScene *, NSUserActivity *);
typedef void (*ATFSceneConnectIMP)(id, SEL, UIScene *, UISceneSession *, UISceneConnectionOptions *);

static BOOL ATFAppContinue(id self, SEL cmd, UIApplication *app, NSUserActivity *activity, void (^restore)(NSArray *)) {
    ATFCaptureActivity(activity);
    ATFAppContinueIMP original = (ATFAppContinueIMP)ATFOriginal(self, cmd);
    return original ? original(self, cmd, app, activity, restore) : YES;
}

static BOOL ATFAppFinish(id self, SEL cmd, UIApplication *app, NSDictionary *options) {
    for (id value in options.allValues) {
        if ([value isKindOfClass:[NSURL class]]) ATFCaptureURL(value);
        else if ([value isKindOfClass:[NSUserActivity class]]) ATFCaptureActivity(value);
    }
    ATFAppFinishIMP original = (ATFAppFinishIMP)ATFOriginal(self, cmd);
    return original ? original(self, cmd, app, options) : YES;
}

static void ATFSceneContinue(id self, SEL cmd, UIScene *scene, NSUserActivity *activity) {
    ATFCaptureActivity(activity);
    ATFSceneContinueIMP original = (ATFSceneContinueIMP)ATFOriginal(self, cmd);
    if (original) original(self, cmd, scene, activity);
}

static void ATFSceneConnect(id self, SEL cmd, UIScene *scene, UISceneSession *session, UISceneConnectionOptions *options) {
    for (NSUserActivity *activity in options.userActivities) ATFCaptureActivity(activity);
    for (UIOpenURLContext *context in options.URLContexts) ATFCaptureURL(context.URL);
    ATFSceneConnectIMP original = (ATFSceneConnectIMP)ATFOriginal(self, cmd);
    if (original) original(self, cmd, scene, session, options);
}

static BOOL ATFClassInApp(Class cls) {
    const char *image = class_getImageName(cls);
    if (!image) return NO;
    NSString *path = [NSString stringWithUTF8String:image];
    return [path hasPrefix:NSBundle.mainBundle.bundlePath];
}

static void ATFScanClasses(void) {
    if (!ATFIsAllTrails()) return;
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);

    SEL appFinish = @selector(application:didFinishLaunchingWithOptions:);
    SEL appContinue = @selector(application:continueUserActivity:restorationHandler:);
    SEL sceneConnect = @selector(scene:willConnectToSession:options:);
    SEL sceneContinue = @selector(scene:continueUserActivity:);

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!cls || !ATFClassInApp(cls)) continue;
        if (class_getInstanceMethod(cls, appFinish) || class_getInstanceMethod(cls, appContinue)) {
            ATFHook(cls, appFinish, (IMP)ATFAppFinish, "c@:@@");
            ATFHook(cls, appContinue, (IMP)ATFAppContinue, "c@:@@@?");
        }
        if (class_getInstanceMethod(cls, sceneConnect) || class_getInstanceMethod(cls, sceneContinue)) {
            ATFHook(cls, sceneConnect, (IMP)ATFSceneConnect, "v@:@@@");
            ATFHook(cls, sceneContinue, (IMP)ATFSceneContinue, "v@:@@");
        }
    }
    free(classes);
}

%ctor {
    if (!ATFIsAllTrails()) return;
    ATFOriginalIMPs = [NSMutableDictionary dictionary];
    ATFHooked = [NSMutableSet set];

    ATFScanClasses();

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
        ATFScanClasses();
        ATFStartDrive();
    }];
    [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
        ATFScanClasses();
        ATFStartDrive();
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
        ATFScanClasses();
        ATFStartDrive();
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ATFScanClasses(); ATFStartDrive(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ATFScanClasses(); ATFStartDrive(); });
}
