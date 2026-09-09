#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "LinkURL.h"

typedef void (^ATOpenCompletion)(BOOL);
static void (*ATOriginalOpen)(id, SEL, NSURL *, NSDictionary *, ATOpenCompletion);
static BOOL (*ATOriginalLegacyOpen)(id, SEL, NSURL *);
static NSURL *(*ATOriginalContextURL)(id, SEL);
static NSURL *(*ATOriginalActivityURL)(id, SEL);
static BOOL (*ATOriginalAppOpen)(id, SEL, UIApplication *, NSURL *, NSDictionary *);
static id (*ATOriginalParser)(id, SEL, NSURL *);
static void (*ATOriginalHostParse)(id, SEL, NSURL *, NSString *, id);

static void ATOpen(id self, SEL selector, NSURL *url, NSDictionary *options, ATOpenCompletion completion) {
    NSURL *transport = ATTransportURL(url);
    if (!transport) { ATOriginalOpen(self, selector, url, options, completion); return; }
    NSMutableDictionary *launchOptions = options ? [options mutableCopy] : [NSMutableDictionary new];
    [launchOptions removeObjectForKey:UIApplicationOpenURLOptionUniversalLinksOnly];
    ATOriginalOpen(self, selector, transport, launchOptions, ^(BOOL success) {
        if (success) { if (completion) completion(YES); }
        else ATOriginalOpen(self, selector, url, options, completion);
    });
}

static BOOL ATLegacyOpen(id self, SEL selector, NSURL *url) {
    NSURL *transport = ATTransportURL(url);
    if (transport && ATOriginalLegacyOpen(self, selector, transport)) return YES;
    return ATOriginalLegacyOpen(self, selector, url);
}

// Cold and warm scene paths read the same property. Preserve the real context
// and let AllTrails perform its own startup sequencing and navigation.
static NSURL *ATContextURL(id self, SEL selector) {
    return ATIncomingURL(ATOriginalContextURL(self, selector));
}
static NSURL *ATActivityURL(id self, SEL selector) {
    return ATIncomingURL(ATOriginalActivityURL(self, selector));
}
static BOOL ATAppOpen(id self, SEL selector, UIApplication *app, NSURL *url, NSDictionary *options) {
    return ATOriginalAppOpen(self, selector, app, ATIncomingURL(url), options);
}
static id ATParser(id self, SEL selector, NSURL *url) {
    return ATOriginalParser(self, selector, ATIncomingURL(url));
}
static void ATHostParse(id self, SEL selector, NSURL *url, NSString *source, id completion) {
    ATOriginalHostParse(self, selector, ATIncomingURL(url), source, completion);
}

static void ATInstall(Class cls, const char *name, IMP replacement, IMP *original) {
    SEL selector = sel_registerName(name);
    if (cls && class_getInstanceMethod(cls, selector)) MSHookMessageEx(cls, selector, replacement, original);
}

__attribute__((constructor)) static void ATInitialize(void) {
    @autoreleasepool {
        BOOL receiver = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.alltrails.AllTrails"];
        if (!receiver) {
            ATInstall(UIApplication.class, "openURL:options:completionHandler:", (IMP)ATOpen, (IMP *)&ATOriginalOpen);
            ATInstall(UIApplication.class, "openURL:", (IMP)ATLegacyOpen, (IMP *)&ATOriginalLegacyOpen);
            return;
        }
        ATInstall(UIOpenURLContext.class, "URL", (IMP)ATContextURL, (IMP *)&ATOriginalContextURL);
        ATInstall(NSUserActivity.class, "webpageURL", (IMP)ATActivityURL, (IMP *)&ATOriginalActivityURL);
        ATInstall(NSClassFromString(@"AllTrails.AppDelegate"), "application:openURL:options:", (IMP)ATAppOpen, (IMP *)&ATOriginalAppOpen);
        // Normalize at both boundaries: selecting a host parser alone does not
        // change the URL subsequently supplied to that parser.
        ATInstall(NSClassFromString(@"AllTrails.DeepLinkURLParserFactory"), "parserForURL:", (IMP)ATParser, (IMP *)&ATOriginalParser);
        ATInstall(NSClassFromString(@"AllTrails.AllTrailsHostURLParser"), "featureForURL:source:completion:", (IMP)ATHostParse, (IMP *)&ATOriginalHostParse);
    }
}
