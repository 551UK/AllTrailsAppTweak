#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <notify.h>
#include <string.h>

static NSString * const ATAllTrailsBundleID = @"com.alltrails.AllTrails";
static NSString * const ATNotifyPrefix = @"com.551.alltrailsapptweak";
static NSString * const ATSearchNotify = @"com.551.alltrailsapptweak.search";
static const NSUInteger ATMaxPendingBytes = 480;
static const NSUInteger ATMaxChunks = 60;

static NSString *ATPendingName = nil;
static NSString *ATPendingURLString = nil;
static int ATDarwinToken = 0;
static __weak UIResponder *ATCapturedResponder = nil;
static BOOL ATLegacyRouteTried = NO;
static BOOL ATSearchActivated = NO;
static NSUInteger ATLastSubmitAttempt = NSNotFound;

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

static NSInteger ATTrailComponentIndex(NSArray<NSString *> *parts) {
    for (NSUInteger i = 0; i < parts.count; i++) {
        if ([parts[i].lowercaseString isEqualToString:@"trail"]) return (NSInteger)i;
    }
    return NSNotFound;
}

static NSString *ATTrailName(NSURL *url) {
    if (!ATIsAllTrailsWebURL(url)) return nil;

    NSArray<NSString *> *parts = ATPathParts(url);
    NSInteger trailIndex = ATTrailComponentIndex(parts);
    if (trailIndex == NSNotFound || (NSUInteger)trailIndex + 1 >= parts.count) return nil;

    NSString *slug = parts.lastObject;
    if (!slug.length) return nil;

    NSString *decoded = [slug stringByRemovingPercentEncoding] ?: slug;
    NSString *name = [decoded stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSURL *ATLegacyCanonicalURL(NSURL *url) {
    if (!ATIsAllTrailsWebURL(url)) return nil;

    NSArray<NSString *> *parts = ATPathParts(url);
    NSInteger trailIndex = ATTrailComponentIndex(parts);
    if (trailIndex == NSNotFound) return nil;

    NSArray<NSString *> *trailParts = [parts subarrayWithRange:NSMakeRange((NSUInteger)trailIndex,
                                                                          parts.count - (NSUInteger)trailIndex)];
    NSString *path = [@"/" stringByAppendingString:[trailParts componentsJoinedByString:@"/"]];

    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"https";
    components.host = @"www.alltrails.com";
    components.path = path;
    return components.URL;
}

#pragma mark - Cross-process handoff

static NSString *ATStateKey(NSString *field, NSString *suffix) {
    return [NSString stringWithFormat:@"%@.%@.%@", ATNotifyPrefix, field, suffix];
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

static BOOL ATWriteStringState(NSString *field, NSString *value) {
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!utf8.length) {
        ATSetNotifyState(ATStateKey(field, @"length"), 0);
        return NO;
    }

    NSUInteger length = MIN(utf8.length, ATMaxPendingBytes);
    NSUInteger chunks = (length + 7) / 8;
    if (chunks > ATMaxChunks) return NO;

    const uint8_t *bytes = utf8.bytes;
    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t word = 0;
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, length - offset);
        memcpy(&word, bytes + offset, count);
        if (!ATSetNotifyState(ATStateKey(field, [NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), word)) {
            return NO;
        }
    }

    return ATSetNotifyState(ATStateKey(field, @"length"), (uint64_t)length);
}

static NSString *ATReadStringState(NSString *field) {
    uint64_t length64 = 0;
    if (!ATGetNotifyState(ATStateKey(field, @"length"), &length64)) return nil;

    NSUInteger length = (NSUInteger)length64;
    if (!length || length > ATMaxPendingBytes) return nil;

    NSUInteger chunks = (length + 7) / 8;
    if (chunks > ATMaxChunks) return nil;

    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = data.mutableBytes;

    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t word = 0;
        if (!ATGetNotifyState(ATStateKey(field, [NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), &word)) {
            return nil;
        }
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, length - offset);
        memcpy(bytes + offset, &word, count);
    }

    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static BOOL ATWritePendingIPC(NSString *name, NSURL *legacyURL) {
    if (!name.length) return NO;

    BOOL wroteName = ATWriteStringState(@"name", name);
    BOOL wroteURL = legacyURL.absoluteString.length ? ATWriteStringState(@"url", legacyURL.absoluteString) : YES;

    uint64_t now = (uint64_t)[[NSDate date] timeIntervalSince1970];
    BOOL wroteTime = ATSetNotifyState(ATStateKey(@"meta", @"time"), now);

    if (wroteName && wroteURL && wroteTime) {
        notify_post(ATSearchNotify.UTF8String);
        return YES;
    }
    return NO;
}

static BOOL ATPendingIsFresh(void) {
    uint64_t time64 = 0;
    if (!ATGetNotifyState(ATStateKey(@"meta", @"time"), &time64)) return NO;
    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - (NSTimeInterval)time64;
    return age >= -5.0 && age <= 120.0;
}

static void ATAdoptPendingIPC(void) {
    if (!ATPendingIsFresh()) return;

    NSString *name = ATReadStringState(@"name");
    NSString *urlString = ATReadStringState(@"url");

    if (name.length) ATPendingName = [name copy];
    if (urlString.length) ATPendingURLString = [urlString copy];
}

static void ATClearPending(void) {
    ATPendingName = nil;
    ATPendingURLString = nil;
    ATLegacyRouteTried = NO;
    ATSearchActivated = NO;
    ATLastSubmitAttempt = NSNotFound;

    if (ATIsAllTrailsProcess()) {
        ATSetNotifyState(ATStateKey(@"name", @"length"), 0);
        ATSetNotifyState(ATStateKey(@"url", @"length"), 0);
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

#pragma mark - Legacy universal-link delivery

static BOOL ATViewTextContainsQuery(UIView *view, NSString *query);

static BOOL ATTryLegacyUniversalLink(void) {
    if (!ATIsAllTrailsProcess() || ATLegacyRouteTried || !ATPendingURLString.length) return NO;
    ATLegacyRouteTried = YES;

    NSURL *url = [NSURL URLWithString:ATPendingURLString];
    if (!url) return NO;

    NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = url;

    UIApplication *app = UIApplication.sharedApplication;
    BOOL delivered = NO;

    if (@available(iOS 13.0, *)) {
        SEL sceneSelector = NSSelectorFromString(@"scene:continueUserActivity:");
        for (UIScene *scene in app.connectedScenes) {
            id delegate = scene.delegate;
            if (delegate && [delegate respondsToSelector:sceneSelector]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sceneSelector, scene, activity);
                delivered = YES;
            }
        }
    }

    if (!delivered) {
        id delegate = app.delegate;
        SEL appSelector = NSSelectorFromString(@"application:continueUserActivity:restorationHandler:");
        if (delegate && [delegate respondsToSelector:appSelector]) {
            void (^restoration)(NSArray *) = ^(__unused NSArray *objects) {};
            delivered = ((BOOL (*)(id, SEL, id, id, id))objc_msgSend)(delegate,
                                                                       appSelector,
                                                                       app,
                                                                       activity,
                                                                       restoration);
        }
    }

    return delivered;
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

static NSString *ATNormalizedText(NSString *text) {
    if (!text.length) return @"";
    NSString *lower = text.lowercaseString;
    NSCharacterSet *keep = [NSCharacterSet alphanumericCharacterSet];
    NSMutableString *out = [NSMutableString stringWithCapacity:lower.length];
    BOOL lastSpace = NO;

    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ([keep characterIsMember:c]) {
            [out appendFormat:@"%C", c];
            lastSpace = NO;
        } else if (!lastSpace) {
            [out appendString:@" "];
            lastSpace = YES;
        }
    }
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
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
    return CGRectGetWidth(view.bounds) > 10.0 && CGRectGetHeight(view.bounds) > 8.0;
}

static NSString *ATAXString(id object) {
    if (!object) return @"";

    NSMutableArray<NSString *> *pieces = [NSMutableArray array];
    SEL selectors[] = {
        @selector(accessibilityLabel),
        @selector(accessibilityHint),
        @selector(accessibilityValue)
    };

    for (NSUInteger i = 0; i < 3; i++) {
        SEL sel = selectors[i];
        if (![object respondsToSelector:sel]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(object, sel);
        if ([value isKindOfClass:[NSString class]] && [value length]) {
            [pieces addObject:value];
        }
    }

    if ([object isKindOfClass:[UILabel class]]) {
        NSString *text = ((UILabel *)object).text;
        if (text.length) [pieces addObject:text];
    } else if ([object isKindOfClass:[UIButton class]]) {
        NSString *title = ((UIButton *)object).currentTitle;
        if (title.length) [pieces addObject:title];
    } else if ([object isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)object;
        if (field.placeholder.length) [pieces addObject:field.placeholder];
        if (field.text.length) [pieces addObject:field.text];
    }

    return [pieces componentsJoinedByString:@" "];
}

static BOOL ATAXActivate(id object) {
    if (!object) return NO;

    if ([object isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)object;
        if (control.enabled && control.userInteractionEnabled) {
            [control sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
    }

    SEL activate = @selector(accessibilityActivate);
    if ([object respondsToSelector:activate]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, activate);
    }

    return NO;
}

static UIButton *ATFindDismissButton(UIView *view) {
    if (!view) return nil;

    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        NSString *text = ATAXString(button);
        if (ATTextContains(text, @"got it") ||
            [text.lowercaseString isEqualToString:@"ok"] ||
            ATTextContains(text, @"dismiss") ||
            ATTextContains(text, @"close")) {
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
    if (ATLooksLikeSearch(field.placeholder)) score += 140;
    if (ATLooksLikeSearch(field.accessibilityLabel)) score += 140;
    if (ATLooksLikeSearch(field.accessibilityHint)) score += 100;
    if (field.returnKeyType == UIReturnKeySearch ||
        field.returnKeyType == UIReturnKeyGo ||
        field.returnKeyType == UIReturnKeyDone) score += 80;
    if (ATTextContains(NSStringFromClass(field.class), @"search")) score += 60;
    if (CGRectGetWidth(field.bounds) > 150.0) score += 10;
    if (field.isFirstResponder) score += 200;
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

static UITabBarController *ATFindTabs(UIViewController *controller) {
    if (!controller) return nil;
    if ([controller isKindOfClass:[UITabBarController class]]) return (UITabBarController *)controller;

    if (controller.presentedViewController) {
        UITabBarController *tabs = ATFindTabs(controller.presentedViewController);
        if (tabs) return tabs;
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
        NSString *text = [NSString stringWithFormat:@"%@ %@", item.title ?: @"", item.accessibilityLabel ?: @""];
        if (ATLooksLikeSearch(text)) {
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

static id ATFindAXSearchObject(id object, NSUInteger depth) {
    if (!object || depth > 12) return nil;

    NSString *text = ATAXString(object);
    if (ATLooksLikeSearch(text)) {
        if ([object isKindOfClass:[UIControl class]] ||
            [object respondsToSelector:@selector(accessibilityActivate)]) {
            return object;
        }
    }

    if ([object isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)object;

        for (UIView *subview in view.subviews) {
            id found = ATFindAXSearchObject(subview, depth + 1);
            if (found) return found;
        }

        NSArray *elements = view.accessibilityElements;
        if ([elements isKindOfClass:[NSArray class]]) {
            for (id element in elements) {
                if (element == object) continue;
                id found = ATFindAXSearchObject(element, depth + 1);
                if (found) return found;
            }
        }
    }

    return nil;
}

static NSUInteger ATQueryWordMatchScore(NSString *candidate, NSString *query) {
    NSString *a = ATNormalizedText(candidate);
    NSString *b = ATNormalizedText(query);
    if (!a.length || !b.length) return 0;
    if ([a containsString:b]) return 1000;

    NSArray<NSString *> *words = [b componentsSeparatedByString:@" "];
    NSUInteger score = 0;
    for (NSString *word in words) {
        if (word.length < 4) continue;
        if ([a containsString:word]) score++;
    }
    return score;
}

static void ATFindBestAXResult(id object,
                               NSString *query,
                               NSUInteger depth,
                               id *best,
                               NSUInteger *bestScore) {
    if (!object || depth > 14) return;

    NSString *text = ATAXString(object);
    NSUInteger score = ATQueryWordMatchScore(text, query);
    if (score > *bestScore &&
        ([object isKindOfClass:[UIControl class]] ||
         [object respondsToSelector:@selector(accessibilityActivate)])) {
        *best = object;
        *bestScore = score;
    }

    if ([object isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)object;

        for (UIView *subview in view.subviews) {
            ATFindBestAXResult(subview, query, depth + 1, best, bestScore);
        }

        NSArray *elements = view.accessibilityElements;
        if ([elements isKindOfClass:[NSArray class]]) {
            for (id element in elements) {
                if (element == object) continue;
                ATFindBestAXResult(element, query, depth + 1, best, bestScore);
            }
        }
    }
}

static BOOL ATActivateMatchingResult(UIWindow *window, NSString *query) {
    id best = nil;
    NSUInteger bestScore = 0;
    ATFindBestAXResult(window, query, 0, &best, &bestScore);

    NSString *normalized = ATNormalizedText(query);
    NSUInteger significantWords = 0;
    for (NSString *word in [normalized componentsSeparatedByString:@" "]) {
        if (word.length >= 4) significantWords++;
    }

    NSUInteger threshold = significantWords >= 6 ? 4 : (significantWords >= 3 ? 3 : 2);
    if (best && (bestScore >= 1000 || bestScore >= threshold)) {
        return ATAXActivate(best);
    }
    return NO;
}

static BOOL ATViewTextContainsQuery(UIView *view, NSString *query) {
    if (!view || !query.length) return NO;
    if (ATQueryWordMatchScore(ATAXString(view), query) >= 1000) return YES;

    for (UIView *subview in view.subviews) {
        if (ATViewTextContainsQuery(subview, query)) return YES;
    }
    return NO;
}

static UIResponder *ATCurrentFirstResponder(void) {
    ATCapturedResponder = nil;
    [[UIApplication sharedApplication] sendAction:@selector(at_captureAllTrailsFirstResponder:)
                                               to:nil
                                             from:nil
                                         forEvent:nil];
    return ATCapturedResponder;
}

static void ATTypeQueryIntoField(UITextField *field, NSString *query) {
    if (!field || !query.length) return;

    [field becomeFirstResponder];
    field.text = @"";
    [field sendActionsForControlEvents:UIControlEventEditingChanged];

    if ([field respondsToSelector:@selector(insertText:)]) {
        [field insertText:query];
    }
    if (![field.text isEqualToString:query]) field.text = query;

    [field sendActionsForControlEvents:UIControlEventEditingChanged];
    [field sendActionsForControlEvents:UIControlEventValueChanged];
}

static BOOL ATTypeQueryIntoResponder(UIResponder *responder, NSString *query) {
    if (!responder || !query.length) return NO;

    if ([responder isKindOfClass:[UITextField class]]) {
        ATTypeQueryIntoField((UITextField *)responder, query);
        return YES;
    }

    if ([responder conformsToProtocol:@protocol(UIKeyInput)] &&
        [responder respondsToSelector:@selector(insertText:)]) {
        id<UIKeyInput> input = (id<UIKeyInput>)responder;
        if ([input hasText] && [responder respondsToSelector:@selector(selectAll:)]) {
            [responder performSelector:@selector(selectAll:) withObject:nil];
        }
        if ([input hasText]) [input deleteBackward];
        [input insertText:query];
        return YES;
    }

    return NO;
}

static void ATSubmitField(UITextField *field) {
    if (!field) return;

    id<UITextFieldDelegate> delegate = field.delegate;
    if ([delegate respondsToSelector:@selector(textFieldShouldReturn:)]) {
        [delegate textFieldShouldReturn:field];
    }
    [field sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
}

static void ATSubmitBar(UISearchBar *bar, NSString *query) {
    if (!bar || !query.length) return;

    [bar becomeFirstResponder];
    bar.text = query;

    UITextField *field = bar.searchTextField;
    ATTypeQueryIntoField(field, query);

    id<UISearchBarDelegate> delegate = bar.delegate;
    if ([delegate respondsToSelector:@selector(searchBar:textDidChange:)]) {
        [delegate searchBar:bar textDidChange:query];
    }
    if ([delegate respondsToSelector:@selector(searchBarSearchButtonClicked:)]) {
        [delegate searchBarSearchButtonClicked:bar];
    }

    [field sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
}

static BOOL ATTapSearchAreaFallback(UIWindow *window) {
    if (!window) return NO;

    UIEdgeInsets insets = window.safeAreaInsets;
    CGFloat y = MAX(insets.top + 38.0, CGRectGetHeight(window.bounds) * 0.105);
    CGPoint point = CGPointMake(CGRectGetMidX(window.bounds), y);
    UIView *hit = [window hitTest:point withEvent:nil];

    for (UIView *view = hit; view; view = view.superview) {
        if (ATAXActivate(view)) return YES;
    }
    return NO;
}

static BOOL ATTrySearch(NSUInteger attempt) {
    NSString *query = ATPendingName;
    if (!query.length) return YES;

    UIWindow *window = ATWindow();
    if (!window) return NO;

    if (ATViewTextContainsQuery(window, query) && !ATSearchActivated) {
        ATClearPending();
        return YES;
    }

    UIButton *dismiss = ATFindDismissButton(window);
    if (dismiss) {
        [dismiss sendActionsForControlEvents:UIControlEventTouchUpInside];
        return NO;
    }

    UITabBarController *tabs = ATFindTabs(window.rootViewController);
    ATSelectExplore(tabs);

    if (ATSearchActivated && ATActivateMatchingResult(window, query)) {
        ATClearPending();
        return YES;
    }

    UISearchBar *bar = ATFindSearchBar(window);
    if (bar) {
        if (ATLastSubmitAttempt == NSNotFound || attempt - ATLastSubmitAttempt >= 4) {
            ATSubmitBar(bar, query);
            ATLastSubmitAttempt = attempt;
            ATSearchActivated = YES;
        }
        return NO;
    }

    UITextField *field = ATFindSearchField(window);
    if (field) {
        if (ATLastSubmitAttempt == NSNotFound || attempt - ATLastSubmitAttempt >= 4) {
            ATTypeQueryIntoField(field, query);
            ATSubmitField(field);
            ATLastSubmitAttempt = attempt;
            ATSearchActivated = YES;
        }
        return NO;
    }

    UIResponder *responder = ATCurrentFirstResponder();
    if (responder && ATTypeQueryIntoResponder(responder, query)) {
        if ([responder isKindOfClass:[UITextField class]]) {
            ATSubmitField((UITextField *)responder);
        }
        ATLastSubmitAttempt = attempt;
        ATSearchActivated = YES;
        return NO;
    }

    id axSearch = ATFindAXSearchObject(window, 0);
    if (axSearch && ATAXActivate(axSearch)) {
        ATSearchActivated = YES;
        return NO;
    }

    if (!ATSearchActivated && ATTapSearchAreaFallback(window)) {
        ATSearchActivated = YES;
        return NO;
    }

    return NO;
}

static void ATRetrySearch(NSUInteger attempt) {
    if (!ATPendingName.length) return;
    if (ATTrySearch(attempt)) return;
    if (attempt + 1 >= 45 || !ATPendingName.length) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ATRetrySearch(attempt + 1);
    });
}

static void ATStartSearch(void) {
    if (!ATIsAllTrailsProcess() || !ATPendingName.length) return;

    if (!ATLegacyRouteTried) {
        ATTryLegacyUniversalLink();
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.00 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ATRetrySearch(0);
    });
}

#pragma mark - Hooks

%hook UIResponder

%new
- (void)at_captureAllTrailsFirstResponder:(id)sender {
    (void)sender;
    ATCapturedResponder = self;
}

%end

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

    NSURL *legacyURL = ATLegacyCanonicalURL(url);
    ATWritePendingIPC(name, legacyURL);

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

    NSURL *legacyURL = ATLegacyCanonicalURL(url);
    ATWritePendingIPC(name, legacyURL);

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
