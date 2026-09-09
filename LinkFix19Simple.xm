#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <string.h>

static NSString * const L19SBundleID = @"com.alltrails.AllTrails";
static NSString * const L19SPrefix = @"com.551.alltrailsapptweak";
static NSString * const L19SNotify = @"com.551.alltrailsapptweak.search";
static int L19SNotifyToken = 0;
static BOOL L19SDriving = NO;
static NSUInteger L19SGeneration = 0;

static BOOL L19SIsAllTrails(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundle length]) return NO;
    return [bundle isEqualToString:L19SBundleID] ||
           [bundle caseInsensitiveCompare:@"com.alltrails.alltrails"] == NSOrderedSame;
}

static NSString *L19SNameFromURL(NSURL *url) {
    if (!url) return nil;
    NSString *scheme = [[url scheme] lowercaseString];
    NSString *host = [[url host] lowercaseString];
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) return nil;
    if (!([host isEqualToString:@"alltrails.com"] || [host isEqualToString:@"www.alltrails.com"] || [host hasSuffix:@".alltrails.com"])) return nil;

    NSArray *parts = [[url path] componentsSeparatedByString:@"/"];
    BOOL sawTrail = NO;
    NSString *slug = nil;
    for (NSString *part in parts) {
        if (![part length]) continue;
        if ([[part lowercaseString] isEqualToString:@"trail"]) sawTrail = YES;
        slug = part;
    }
    if (!sawTrail || ![slug length]) return nil;

    NSString *decoded = [slug stringByRemovingPercentEncoding] ?: slug;
    NSString *name = [decoded stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    name = [name stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    while ([name rangeOfString:@"  "].location != NSNotFound) {
        name = [name stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *L19SKey(NSString *suffix) {
    return [NSString stringWithFormat:@"%@.%@", L19SPrefix, suffix];
}

static BOOL L19SSetState(NSString *name, uint64_t value) {
    int token = 0;
    if (notify_register_check([name UTF8String], &token) != 0) return NO;
    int result = notify_set_state(token, value);
    notify_cancel(token);
    return result == 0;
}

static BOOL L19SGetState(NSString *name, uint64_t *value) {
    int token = 0;
    if (!value || notify_register_check([name UTF8String], &token) != 0) return NO;
    int result = notify_get_state(token, value);
    notify_cancel(token);
    return result == 0;
}

static BOOL L19SWritePending(NSString *name) {
    NSData *data = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (![data length] || [data length] > 1024) return NO;
    const uint8_t *bytes = (const uint8_t *)[data bytes];
    NSUInteger chunks = ([data length] + 7) / 8;
    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t word = 0;
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, [data length] - offset);
        memcpy(&word, bytes + offset, count);
        if (!L19SSetState(L19SKey([NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), word)) return NO;
    }
    if (!L19SSetState(L19SKey(@"length"), (uint64_t)[data length])) return NO;
    if (!L19SSetState(L19SKey(@"time"), (uint64_t)[[NSDate date] timeIntervalSince1970])) return NO;
    notify_post([L19SNotify UTF8String]);
    return YES;
}

static NSString *L19SReadPending(void) {
    uint64_t length64 = 0, time64 = 0;
    if (!L19SGetState(L19SKey(@"length"), &length64)) return nil;
    if (!L19SGetState(L19SKey(@"time"), &time64)) return nil;
    NSUInteger length = (NSUInteger)length64;
    if (!length || length > 1024) return nil;
    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - (NSTimeInterval)time64;
    if (age < -5.0 || age > 180.0) return nil;

    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = (uint8_t *)[data mutableBytes];
    NSUInteger chunks = (length + 7) / 8;
    for (NSUInteger i = 0; i < chunks; i++) {
        uint64_t word = 0;
        if (!L19SGetState(L19SKey([NSString stringWithFormat:@"chunk.%lu", (unsigned long)i]), &word)) return nil;
        NSUInteger offset = i * 8;
        NSUInteger count = MIN((NSUInteger)8, length - offset);
        memcpy(bytes + offset, &word, count);
    }
    NSString *name = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void L19SCapture(NSURL *url) {
    NSString *name = L19SNameFromURL(url);
    if ([name length]) L19SWritePending(name);
}

#pragma mark - Lower-level outgoing URL capture

typedef BOOL (*L19SOpen1IMP)(id, SEL, NSURL *);
typedef BOOL (*L19SOpen2IMP)(id, SEL, NSURL *, NSDictionary *);
typedef BOOL (*L19SOpen3IMP)(id, SEL, NSURL *, NSDictionary *, NSError **);
typedef void (*L19SOpen4IMP)(id, SEL, NSURL *, id, id);

static L19SOpen1IMP L19SOrigOpen1 = NULL;
static L19SOpen2IMP L19SOrigOpen2 = NULL;
static L19SOpen3IMP L19SOrigOpen3 = NULL;
static L19SOpen4IMP L19SOrigOpen4 = NULL;

static BOOL L19SOpen1(id self, SEL cmd, NSURL *url) {
    L19SCapture(url);
    return L19SOrigOpen1 ? L19SOrigOpen1(self, cmd, url) : NO;
}
static BOOL L19SOpen2(id self, SEL cmd, NSURL *url, NSDictionary *options) {
    L19SCapture(url);
    return L19SOrigOpen2 ? L19SOrigOpen2(self, cmd, url, options) : NO;
}
static BOOL L19SOpen3(id self, SEL cmd, NSURL *url, NSDictionary *options, NSError **error) {
    L19SCapture(url);
    return L19SOrigOpen3 ? L19SOrigOpen3(self, cmd, url, options, error) : NO;
}
static void L19SOpen4(id self, SEL cmd, NSURL *url, id configuration, id completion) {
    L19SCapture(url);
    if (L19SOrigOpen4) L19SOrigOpen4(self, cmd, url, configuration, completion);
}

static void L19SHookWorkspace(void) {
    if (L19SIsAllTrails()) return;
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls) return;

    Method m1 = class_getInstanceMethod(cls, @selector(openURL:));
    if (m1 && method_getImplementation(m1) != (IMP)L19SOpen1 && !L19SOrigOpen1) {
        L19SOrigOpen1 = (L19SOpen1IMP)method_getImplementation(m1);
        method_setImplementation(m1, (IMP)L19SOpen1);
    }

    SEL s2 = NSSelectorFromString(@"openURL:withOptions:");
    Method m2 = class_getInstanceMethod(cls, s2);
    if (m2 && method_getImplementation(m2) != (IMP)L19SOpen2 && !L19SOrigOpen2) {
        L19SOrigOpen2 = (L19SOpen2IMP)method_getImplementation(m2);
        method_setImplementation(m2, (IMP)L19SOpen2);
    }

    SEL s3 = NSSelectorFromString(@"openURL:withOptions:error:");
    Method m3 = class_getInstanceMethod(cls, s3);
    if (m3 && method_getImplementation(m3) != (IMP)L19SOpen3 && !L19SOrigOpen3) {
        L19SOrigOpen3 = (L19SOpen3IMP)method_getImplementation(m3);
        method_setImplementation(m3, (IMP)L19SOpen3);
    }

    SEL s4 = NSSelectorFromString(@"openURL:configuration:completionHandler:");
    Method m4 = class_getInstanceMethod(cls, s4);
    if (m4 && method_getImplementation(m4) != (IMP)L19SOpen4 && !L19SOrigOpen4) {
        L19SOrigOpen4 = (L19SOpen4IMP)method_getImplementation(m4);
        method_setImplementation(m4, (IMP)L19SOpen4);
    }
}

#pragma mark - AllTrails Find cities UI driver

static UIWindow *L19SWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [app connectedScenes]) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in [(UIWindowScene *)scene windows]) if ([window isKeyWindow]) return window;
            for (UIWindow *window in [(UIWindowScene *)scene windows]) if (![window isHidden] && [window alpha] > 0.05) return window;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [app keyWindow];
#pragma clang diagnostic pop
}

static BOOL L19SVisible(UIView *view) {
    if (!view || ![view window] || [view isHidden] || [view alpha] < 0.05) return NO;
    return CGRectGetWidth([view bounds]) > 3.0 && CGRectGetHeight([view bounds]) > 3.0;
}

static NSString *L19SViewText(UIView *view) {
    NSMutableArray *parts = [NSMutableArray array];
    if ([view isKindOfClass:[UILabel class]] && [[(UILabel *)view text] length]) [parts addObject:[(UILabel *)view text]];
    if ([view isKindOfClass:[UIButton class]] && [[(UIButton *)view currentTitle] length]) [parts addObject:[(UIButton *)view currentTitle]];
    if ([view isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)view;
        if ([[field placeholder] length]) [parts addObject:[field placeholder]];
        if ([[field text] length]) [parts addObject:[field text]];
    }
    if ([view isKindOfClass:[UISearchBar class]]) {
        UISearchBar *bar = (UISearchBar *)view;
        if ([[bar placeholder] length]) [parts addObject:[bar placeholder]];
        if ([[bar text] length]) [parts addObject:[bar text]];
    }
    if ([[view accessibilityLabel] length]) [parts addObject:[view accessibilityLabel]];
    if ([[view accessibilityValue] length]) [parts addObject:[view accessibilityValue]];
    return [parts count] ? [parts componentsJoinedByString:@" "] : @"";
}

static BOOL L19SContains(NSString *text, NSArray *needles) {
    NSString *lower = [text lowercaseString];
    if (![lower length]) return NO;
    for (NSString *needle in needles) if ([lower rangeOfString:[needle lowercaseString]].location != NSNotFound) return YES;
    return NO;
}

static NSString *L19SNormalize(NSString *text) {
    NSString *lower = [[text stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:[NSLocale currentLocale]] lowercaseString];
    NSMutableString *result = [NSMutableString string];
    BOOL lastSpace = NO;
    NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < [lower length]; i++) {
        unichar c = [lower characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [result appendFormat:@"%C", c];
            lastSpace = NO;
        } else if (!lastSpace && [result length]) {
            [result appendString:@" "];
            lastSpace = YES;
        }
    }
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

static UIView *L19SFind(UIWindow *window, BOOL (^predicate)(UIView *)) {
    if (!window || !predicate) return nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:window];
    while ([stack count]) {
        UIView *view = [stack lastObject];
        [stack removeLastObject];
        if (L19SVisible(view) && predicate(view)) return view;
        for (UIView *child in [[view subviews] reverseObjectEnumerator]) [stack addObject:child];
    }
    return nil;
}

static BOOL L19SActivate(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = [candidate superview]) {
        if ([candidate isKindOfClass:[UIControl class]]) {
            [(UIControl *)candidate sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        if ([candidate respondsToSelector:@selector(accessibilityActivate)] && [candidate accessibilityActivate]) return YES;
    }
    return NO;
}

static BOOL L19SMatches(NSString *candidateText, NSString *query) {
    NSString *candidate = L19SNormalize(candidateText);
    NSString *wanted = L19SNormalize(query);
    if (![candidate length] || ![wanted length]) return NO;
    if ([candidate rangeOfString:wanted].location != NSNotFound) return YES;

    NSSet *ignored = [NSSet setWithObjects:@"and", @"the", @"via", @"trail", @"circular", @"loop", nil];
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *token in [wanted componentsSeparatedByString:@" "]) {
        if ([token length] >= 3 && ![ignored containsObject:token]) [tokens addObject:token];
    }
    NSUInteger matched = 0;
    for (NSString *token in tokens) if ([candidate rangeOfString:token].location != NSNotFound) matched++;
    return [tokens count] >= 2 && matched >= MAX((NSUInteger)2, ([tokens count] + 1) / 2);
}

static void L19SSubmitField(UITextField *field, NSString *query) {
    [field becomeFirstResponder];
    [field setText:@""];
    [field sendActionsForControlEvents:UIControlEventEditingChanged];
    [field insertText:query];
    [field setText:query];
    [field sendActionsForControlEvents:UIControlEventEditingChanged];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id delegate = [field delegate];
        if ([delegate respondsToSelector:@selector(textFieldShouldReturn:)]) [delegate textFieldShouldReturn:field];
        [field sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
        [[UIApplication sharedApplication] sendAction:NSSelectorFromString(@"insertNewline:") to:nil from:nil forEvent:nil];
    });
}

static void L19SSubmitBar(UISearchBar *bar, NSString *query) {
    [bar becomeFirstResponder];
    [bar setText:query];
    if (@available(iOS 13.0, *)) {
        [[bar searchTextField] setText:query];
        [[bar searchTextField] sendActionsForControlEvents:UIControlEventEditingChanged];
    }
    id delegate = [bar delegate];
    if ([delegate respondsToSelector:@selector(searchBar:textDidChange:)]) [delegate searchBar:bar textDidChange:query];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id currentDelegate = [bar delegate];
        if ([currentDelegate respondsToSelector:@selector(searchBarSearchButtonClicked:)]) [currentDelegate searchBarSearchButtonClicked:bar];
        [[UIApplication sharedApplication] sendAction:NSSelectorFromString(@"insertNewline:") to:nil from:nil forEvent:nil];
    });
}

static void L19SDrive(NSUInteger generation, NSUInteger attempt) {
    if (generation != L19SGeneration || !L19SIsAllTrails()) { L19SDriving = NO; return; }
    NSString *query = L19SReadPending();
    if (![query length] || attempt >= 80) { L19SDriving = NO; return; }
    UIWindow *window = L19SWindow();
    if (!window) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ L19SDrive(generation, attempt + 1); });
        return;
    }

    UIView *match = L19SFind(window, ^BOOL(UIView *view) {
        if ([view isKindOfClass:[UITextField class]] || [view isKindOfClass:[UISearchBar class]]) return NO;
        return L19SMatches(L19SViewText(view), query);
    });
    if (match && L19SActivate(match)) {
        L19SSetState(L19SKey(@"length"), 0);
        L19SDriving = NO;
        return;
    }

    UISearchBar *bar = (UISearchBar *)L19SFind(window, ^BOOL(UIView *view) {
        return [view isKindOfClass:[UISearchBar class]];
    });
    if (bar) {
        if (![L19SNormalize([bar text]) isEqualToString:L19SNormalize(query)]) L19SSubmitBar(bar, query);
    } else {
        UITextField *field = (UITextField *)L19SFind(window, ^BOOL(UIView *view) {
            if (![view isKindOfClass:[UITextField class]]) return NO;
            NSString *text = L19SViewText(view);
            NSString *cls = [NSStringFromClass([view class]) lowercaseString];
            return L19SContains(text, @[@"find cities", @"find city", @"search", @"trail", @"city", @"park", @"place", @"location"]) ||
                   [cls rangeOfString:@"search"].location != NSNotFound;
        });
        if (field) {
            if (![L19SNormalize([field text]) isEqualToString:L19SNormalize(query)]) L19SSubmitField(field, query);
        } else {
            UIView *control = L19SFind(window, ^BOOL(UIView *view) {
                return L19SContains(L19SViewText(view), @[@"find cities", @"find city", @"find a city", @"find a trail", @"find trails", @"search"]);
            });
            if (control) L19SActivate(control);
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.42 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ L19SDrive(generation, attempt + 1); });
}

static void L19SStartDrive(void) {
    if (!L19SIsAllTrails() || L19SDriving || ![L19SReadPending() length]) return;
    L19SGeneration++;
    L19SDriving = YES;
    NSUInteger generation = L19SGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ L19SDrive(generation, 0); });
}

%hook UILabel
- (void)setText:(NSString *)text {
    if (L19SIsAllTrails() && [text isEqualToString:@"AllTrails link fix 1.0.18 loaded"]) {
        text = @"AllTrails link fix 1.0.19 loaded";
    }
    %orig(text);
}
%end

%ctor {
    %init;

    if (L19SIsAllTrails()) {
        notify_register_dispatch([L19SNotify UTF8String], &L19SNotifyToken, dispatch_get_main_queue(), ^(__unused int token) {
            L19SStartDrive();
        });
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
            L19SStartDrive();
        }];
        [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
            L19SStartDrive();
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ L19SStartDrive(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.50 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ L19SStartDrive(); });
    } else {
        L19SHookWorkspace();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ L19SHookWorkspace(); });
    }
}
