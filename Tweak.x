#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <notify.h>
#include <string.h>

static NSString * const ATAllTrailsBundleID = @"com.alltrails.AllTrails";
static NSString * const ATNotifyPrefix = @"com.551.alltrailsapptweak";
static NSString * const ATSearchNotify = @"com.551.alltrailsapptweak.search";
static const NSUInteger ATMaxPendingBytes = 1024;
static const NSUInteger ATMaxChunks = 128;

static NSString *ATPendingName = nil;
static int ATDarwinToken = 0;
static NSUInteger ATGeneration = 0;
static BOOL ATFlowRunning = NO;
static BOOL ATDidActivateExplore = NO;
static BOOL ATDidActivateSearch = NO;
static BOOL ATDidSubmitQuery = NO;

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

static NSArray<NSString *> *ATPathParts(NSURL *url) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [url.path componentsSeparatedByString:@"/"]) {
        if (part.length) [parts addObject:part];
    }
    return parts;
}

static NSString *ATTrailNameFromURL(NSURL *url) {
    if (!ATIsAllTrailsWebURL(url)) return nil;

    NSArray<NSString *> *parts = ATPathParts(url);
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

#pragma mark - Cross-process handoff

static NSString *ATStateKey(NSString *suffix) {
    return [NSString stringWithFormat:@"%@.%@", ATNotifyPrefix, suffix];
}

static BOOL ATSetState(NSString *name, uint64_t state) {
    int token = 0;
    if (notify_register_check(name.UTF8String, &token) != 0) return NO;
    int result = notify_set_state(token, state);
    notify_cancel(token);
    return result == 0;
}

static BOOL ATGetState(NSString *name, uint64_t *state) {
    if (!state) return NO;
    int token = 0;
    if (notify_register_check(name.UTF8String, &token) != 0) return NO;
    int result = notify_get_state(token, state);
    notify_cancel(token);
    return result == 0;
}

static BOOL ATWritePendingName(NSString *name) {
    if (!name.length) return NO;

    NSData *data = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length || data.length > ATMaxPendingBytes) return NO;

    NSUInteger chunks = (data.length + 7) / 8;
    if (chunks > ATMaxChunks) return NO;

    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t word = 0;
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, data.length - offset);
        memcpy(&word, bytes + offset, count);
        if (!ATSetState(ATStateKey([NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), word)) {
            return NO;
        }
    }

    if (!ATSetState(ATStateKey(@"length"), (uint64_t)data.length)) return NO;
    if (!ATSetState(ATStateKey(@"time"), (uint64_t)[[NSDate date] timeIntervalSince1970])) return NO;

    notify_post(ATSearchNotify.UTF8String);
    return YES;
}

static NSString *ATReadPendingName(void) {
    uint64_t length64 = 0;
    uint64_t time64 = 0;
    if (!ATGetState(ATStateKey(@"length"), &length64)) return nil;
    if (!ATGetState(ATStateKey(@"time"), &time64)) return nil;

    NSUInteger length = (NSUInteger)length64;
    if (!length || length > ATMaxPendingBytes) return nil;

    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - (NSTimeInterval)time64;
    if (age < -5.0 || age > 180.0) return nil;

    NSUInteger chunks = (length + 7) / 8;
    if (chunks > ATMaxChunks) return nil;

    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t word = 0;
        if (!ATGetState(ATStateKey([NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), &word)) return nil;
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, length - offset);
        memcpy(bytes + offset, &word, count);
    }

    NSString *name = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL ATAdoptPending(void) {
    NSString *name = ATReadPendingName();
    if (!name.length) return NO;

    if (![ATPendingName isEqualToString:name]) {
        ATPendingName = name;
        ATGeneration++;
        ATDidActivateExplore = NO;
        ATDidActivateSearch = NO;
        ATDidSubmitQuery = NO;
        ATFlowRunning = NO;
        return YES;
    }

    if (!ATPendingName.length) {
        ATPendingName = name;
        ATGeneration++;
        ATDidActivateExplore = NO;
        ATDidActivateSearch = NO;
        ATDidSubmitQuery = NO;
        ATFlowRunning = NO;
        return YES;
    }

    return NO;
}

static void ATClearPending(NSUInteger generation) {
    if (generation != ATGeneration) return;
    ATPendingName = nil;
    ATFlowRunning = NO;
    ATDidActivateExplore = NO;
    ATDidActivateSearch = NO;
    ATDidSubmitQuery = NO;
    ATSetState(ATStateKey(@"length"), 0);
}

static BOOL ATLaunchAllTrails(void) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
    SEL openSelector = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSelector]) return NO;

    id workspace = ((id (*)(id, SEL))objc_msgSend)((id)workspaceClass, defaultSelector);
    if (!workspace || ![workspace respondsToSelector:openSelector]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, openSelector, ATAllTrailsBundleID);
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

static BOOL ATViewVisible(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.05 || !view.window) return NO;
    CGRect rect = [view convertRect:view.bounds toView:nil];
    return CGRectGetWidth(rect) > 8.0 && CGRectGetHeight(rect) > 8.0;
}

static NSString *ATObjectText(id object) {
    if (!object) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    if ([object isKindOfClass:[UILabel class]]) {
        NSString *text = ((UILabel *)object).text;
        if (text.length) [parts addObject:text];
    }
    if ([object isKindOfClass:[UIButton class]]) {
        NSString *text = ((UIButton *)object).currentTitle;
        if (text.length) [parts addObject:text];
    }
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
    if ([object respondsToSelector:@selector(accessibilityHint)]) {
        NSString *text = [object accessibilityHint];
        if (text.length) [parts addObject:text];
    }

    return parts.count ? [parts componentsJoinedByString:@" "] : nil;
}

static NSString *ATNormalized(NSString *text) {
    if (!text.length) return @"";
    NSString *lower = [[text stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:[NSLocale currentLocale]] lowercaseString];
    NSMutableString *result = [NSMutableString string];
    BOOL lastWasSpace = NO;

    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [result appendFormat:@"%C", c];
            lastWasSpace = NO;
        } else if (!lastWasSpace && result.length) {
            [result appendString:@" "];
            lastWasSpace = YES;
        }
    }

    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

static BOOL ATTextContainsAny(NSString *text, NSArray<NSString *> *needles) {
    NSString *lower = text.lowercaseString;
    if (!lower.length) return NO;
    for (NSString *needle in needles) {
        if ([lower rangeOfString:needle].location != NSNotFound) return YES;
    }
    return NO;
}

static UIView *ATFindView(UIView *root, BOOL (^predicate)(UIView *view)) {
    if (!root || !predicate) return nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];

    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (ATViewVisible(view) && predicate(view)) return view;
        for (UIView *child in view.subviews.reverseObjectEnumerator) {
            [stack addObject:child];
        }
    }
    return nil;
}

static UIViewController *ATFindController(UIViewController *root, Class cls) {
    if (!root) return nil;
    if ([root isKindOfClass:cls]) return root;
    if (root.presentedViewController) {
        UIViewController *found = ATFindController(root.presentedViewController, cls);
        if (found) return found;
    }
    if ([root isKindOfClass:[UINavigationController class]]) {
        UIViewController *found = ATFindController(((UINavigationController *)root).visibleViewController, cls);
        if (found) return found;
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in ((UITabBarController *)root).viewControllers) {
            UIViewController *found = ATFindController(child, cls);
            if (found) return found;
        }
    }
    for (UIViewController *child in root.childViewControllers) {
        UIViewController *found = ATFindController(child, cls);
        if (found) return found;
    }
    return nil;
}

static BOOL ATActivateView(UIView *view) {
    if (!view) return NO;

    UIView *candidate = view;
    for (NSUInteger depth = 0; candidate && depth < 10; depth++, candidate = candidate.superview) {
        if ([candidate isKindOfClass:[UIControl class]]) {
            [(UIControl *)candidate sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }

        if ([candidate isKindOfClass:[UITableViewCell class]]) {
            UIView *parent = candidate.superview;
            while (parent && ![parent isKindOfClass:[UITableView class]]) parent = parent.superview;
            if ([parent isKindOfClass:[UITableView class]]) {
                UITableView *table = (UITableView *)parent;
                NSIndexPath *indexPath = [table indexPathForCell:(UITableViewCell *)candidate];
                if (indexPath) {
                    [table selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
                    id<UITableViewDelegate> delegate = table.delegate;
                    if ([delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                        [delegate tableView:table didSelectRowAtIndexPath:indexPath];
                        return YES;
                    }
                }
            }
        }

        if ([candidate isKindOfClass:[UICollectionViewCell class]]) {
            UIView *parent = candidate.superview;
            while (parent && ![parent isKindOfClass:[UICollectionView class]]) parent = parent.superview;
            if ([parent isKindOfClass:[UICollectionView class]]) {
                UICollectionView *collection = (UICollectionView *)parent;
                NSIndexPath *indexPath = [collection indexPathForCell:(UICollectionViewCell *)candidate];
                if (indexPath) {
                    [collection selectItemAtIndexPath:indexPath animated:NO scrollPosition:UICollectionViewScrollPositionNone];
                    id<UICollectionViewDelegate> delegate = collection.delegate;
                    if ([delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                        [delegate collectionView:collection didSelectItemAtIndexPath:indexPath];
                        return YES;
                    }
                }
            }
        }

        if ([candidate respondsToSelector:@selector(accessibilityActivate)] && [candidate accessibilityActivate]) {
            return YES;
        }
    }

    return NO;
}

static BOOL ATSelectExplore(UIWindow *window) {
    if (!window) return NO;

    UITabBarController *tabs = (UITabBarController *)ATFindController(window.rootViewController, [UITabBarController class]);
    if (tabs) {
        NSArray<UIViewController *> *controllers = tabs.viewControllers;
        for (NSUInteger i = 0; i < controllers.count; i++) {
            UIViewController *controller = controllers[i];
            NSString *title = controller.tabBarItem.title ?: controller.title ?: controller.tabBarItem.accessibilityLabel;
            if (ATTextContainsAny(title, @[@"explore", @"discover", @"search"])) {
                tabs.selectedIndex = i;
                return YES;
            }
        }
    }

    UIView *explore = ATFindView(window, ^BOOL(UIView *view) {
        NSString *text = ATObjectText(view);
        return ATTextContainsAny(text, @[@"explore", @"discover"]);
    });
    return explore ? ATActivateView(explore) : NO;
}

static UISearchBar *ATFindSearchBar(UIWindow *window) {
    return (UISearchBar *)ATFindView(window, ^BOOL(UIView *view) {
        return [view isKindOfClass:[UISearchBar class]];
    });
}

static UITextField *ATFindSearchField(UIWindow *window) {
    __block UITextField *fallback = nil;
    UIView *found = ATFindView(window, ^BOOL(UIView *view) {
        if (![view isKindOfClass:[UITextField class]]) return NO;
        UITextField *field = (UITextField *)view;
        if (!fallback) fallback = field;
        NSString *text = ATObjectText(field);
        return ATTextContainsAny(text, @[@"search", @"trail", @"city", @"park", @"place"]);
    });
    return (UITextField *)found ?: fallback;
}

static BOOL ATActivateSearchControl(UIWindow *window) {
    UIView *control = ATFindView(window, ^BOOL(UIView *view) {
        if ([view isKindOfClass:[UILabel class]]) return NO;
        NSString *text = ATObjectText(view);
        return ATTextContainsAny(text, @[@"search", @"find a trail", @"find trails", @"city or park", @"trail or park", @"find places"]);
    });
    return control ? ATActivateView(control) : NO;
}

static void ATSubmitSearchBar(UISearchBar *bar, NSString *query) {
    if (!bar || !query.length) return;
    [bar becomeFirstResponder];
    bar.text = query;

    UITextField *field = nil;
    if (@available(iOS 13.0, *)) field = bar.searchTextField;
    if (field) {
        field.text = query;
        [field sendActionsForControlEvents:UIControlEventEditingChanged];
    }

    id<UISearchBarDelegate> delegate = bar.delegate;
    if ([delegate respondsToSelector:@selector(searchBar:textDidChange:)]) {
        [delegate searchBar:bar textDidChange:query];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id<UISearchBarDelegate> currentDelegate = bar.delegate;
        if ([currentDelegate respondsToSelector:@selector(searchBarSearchButtonClicked:)]) {
            [currentDelegate searchBarSearchButtonClicked:bar];
        }
        if (@available(iOS 13.0, *)) {
            [bar.searchTextField sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
        }
    });
}

static void ATSubmitTextField(UITextField *field, NSString *query) {
    if (!field || !query.length) return;
    [field becomeFirstResponder];
    field.text = @"";
    [field sendActionsForControlEvents:UIControlEventEditingChanged];
    [field insertText:query];
    field.text = query;
    [field sendActionsForControlEvents:UIControlEventEditingChanged];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id<UITextFieldDelegate> delegate = field.delegate;
        if ([delegate respondsToSelector:@selector(textFieldShouldReturn:)]) {
            [delegate textFieldShouldReturn:field];
        }
        [field sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
    });
}

static BOOL ATOpenMatchingResult(UIWindow *window, NSString *query) {
    if (!window || !query.length) return NO;
    NSString *queryNorm = ATNormalized(query);
    if (queryNorm.length < 4) return NO;

    UIView *match = ATFindView(window, ^BOOL(UIView *view) {
        if ([view isKindOfClass:[UITextField class]] || [view isKindOfClass:[UISearchBar class]]) return NO;
        NSString *text = ATObjectText(view);
        NSString *norm = ATNormalized(text);
        if (!norm.length) return NO;
        return [norm rangeOfString:queryNorm].location != NSNotFound;
    });

    if (!match) return NO;
    return ATActivateView(match);
}

static void ATDriveUI(NSUInteger generation, NSUInteger attempt);

static void ATScheduleDrive(NSUInteger generation, NSUInteger attempt, NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ATDriveUI(generation, attempt);
    });
}

static void ATDriveUI(NSUInteger generation, NSUInteger attempt) {
    if (generation != ATGeneration || !ATPendingName.length) {
        ATFlowRunning = NO;
        return;
    }

    if (attempt >= 70) {
        ATClearPending(generation);
        return;
    }

    UIWindow *window = ATWindow();
    if (!window) {
        ATScheduleDrive(generation, attempt + 1, 0.35);
        return;
    }

    if (ATOpenMatchingResult(window, ATPendingName)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ATClearPending(generation);
        });
        return;
    }

    UISearchBar *bar = ATFindSearchBar(window);
    if (bar) {
        NSString *current = ATNormalized(bar.text);
        NSString *wanted = ATNormalized(ATPendingName);
        if (!ATDidSubmitQuery || ![current isEqualToString:wanted]) {
            ATDidSubmitQuery = YES;
            ATSubmitSearchBar(bar, ATPendingName);
        }
        ATScheduleDrive(generation, attempt + 1, 0.45);
        return;
    }

    UITextField *field = ATFindSearchField(window);
    if (field && ATDidActivateSearch) {
        NSString *current = ATNormalized(field.text);
        NSString *wanted = ATNormalized(ATPendingName);
        if (!ATDidSubmitQuery || ![current isEqualToString:wanted]) {
            ATDidSubmitQuery = YES;
            ATSubmitTextField(field, ATPendingName);
        }
        ATScheduleDrive(generation, attempt + 1, 0.45);
        return;
    }

    if (!ATDidActivateExplore || attempt % 8 == 0) {
        if (ATSelectExplore(window)) ATDidActivateExplore = YES;
        ATScheduleDrive(generation, attempt + 1, 0.35);
        return;
    }

    if (!ATDidActivateSearch || attempt % 6 == 0) {
        if (ATActivateSearchControl(window)) ATDidActivateSearch = YES;
        ATScheduleDrive(generation, attempt + 1, 0.35);
        return;
    }

    UITextField *anyField = ATFindSearchField(window);
    if (anyField) {
        ATDidActivateSearch = YES;
        ATDidSubmitQuery = YES;
        ATSubmitTextField(anyField, ATPendingName);
    }

    ATScheduleDrive(generation, attempt + 1, 0.40);
}

static void ATStartUIFlow(void) {
    if (!ATIsAllTrailsProcess()) return;
    ATAdoptPending();
    if (!ATPendingName.length || ATFlowRunning) return;

    ATFlowRunning = YES;
    NSUInteger generation = ATGeneration;
    ATScheduleDrive(generation, 0, 0.40);
}

#pragma mark - Outgoing link interception

%hook UIApplication

- (void)openURL:(NSURL *)url
        options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey, id> *)options
completionHandler:(void (^)(BOOL success))completion {

    NSString *trailName = ATTrailNameFromURL(url);
    if (ATIsAllTrailsProcess() || !trailName.length) {
        %orig;
        return;
    }

    if (!ATWritePendingName(trailName)) {
        %orig;
        return;
    }

    if (ATLaunchAllTrails()) {
        if (completion) completion(YES);
        return;
    }

    NSURL *launcher = [NSURL URLWithString:@"alltrails://"];
    NSMutableDictionary *launchOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
    [launchOptions removeObjectForKey:UIApplicationOpenURLOptionUniversalLinksOnly];
    %orig(launcher, launchOptions, completion);
}

- (BOOL)openURL:(NSURL *)url {
    NSString *trailName = ATTrailNameFromURL(url);
    if (ATIsAllTrailsProcess() || !trailName.length) return %orig;

    if (!ATWritePendingName(trailName)) return %orig;
    if (ATLaunchAllTrails()) return YES;
    return %orig([NSURL URLWithString:@"alltrails://"]);
}

%end

%ctor {
    %init;

    if (!ATIsAllTrailsProcess()) return;

    notify_register_dispatch(ATSearchNotify.UTF8String,
                             &ATDarwinToken,
                             dispatch_get_main_queue(),
                             ^(__unused int token) {
        ATAdoptPending();
        ATStartUIFlow();
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        ATAdoptPending();
        ATStartUIFlow();
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
        ATAdoptPending();
        ATStartUIFlow();
    });
}
