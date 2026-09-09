#import <UIKit/UIKit.h>
#import "LinkURL.h"

static BOOL ATIsReceiver;

static NSDictionary *ATLaunchOptions(NSDictionary *options) {
    NSMutableDictionary *copy = options ? [options mutableCopy] : [NSMutableDictionary new];
    [copy removeObjectForKey:UIApplicationOpenURLOptionUniversalLinksOnly];
    return copy;
}

%group Outgoing
%hook UIApplication
- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))completion {
    NSURL *transport = ATTransportURL(url);
    if (!transport) { %orig; return; }
    // Report actual launch success; use the original web URL if the app cannot open.
    void (^result)(BOOL) = ^(BOOL success) {
        if (success) { if (completion) completion(YES); }
        else { %orig(url, options, completion); }
    };
    NSDictionary *launchOptions = ATLaunchOptions(options);
    %orig(transport, launchOptions, result);
}
- (BOOL)openURL:(NSURL *)url {
    NSURL *transport = ATTransportURL(url);
    if (!transport) return %orig;
    if (%orig(transport)) return YES;
    return %orig(url);
}
%end
%end

%group Incoming
// The app reads this property during both scene connection (cold launch)
// and scene:openURLContexts: (warm launch). Keep the real context/options.
%hook UIOpenURLContext
- (NSURL *)URL { NSURL *url = %orig; return ATIncomingURL(url); }
%end

%hook NSUserActivity
- (NSURL *)webpageURL { NSURL *url = %orig; return ATIncomingURL(url); }
%end
%end

%group AllTrailsDelegates
%hook ATAppDelegate
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options {
    NSURL *normalized = ATIncomingURL(url);
    return %orig(app, normalized, options);
}
%end
%end

// Normalize at both the factory and parser boundaries. The factory chooses
// by scheme; the parser must receive that same normalized URL afterwards.
%group ParserFactory
%hook ATParserFactory
- (id)parserForURL:(NSURL *)url { NSURL *normalized = ATIncomingURL(url); return %orig(normalized); }
%end
%end

%group HostParser
%hook ATHostParser
- (void)featureForURL:(NSURL *)url source:(NSString *)source completion:(id)completion {
    NSURL *normalized = ATIncomingURL(url);
    %orig(normalized, source, completion);
}
%end
%end

%ctor {
    ATIsReceiver = [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.alltrails.AllTrails"];
    if (!ATIsReceiver) { %init(Outgoing); return; }
    %init(Incoming);
    Class app = NSClassFromString(@"AllTrails.AppDelegate");
    Class factory = NSClassFromString(@"AllTrails.DeepLinkURLParserFactory");
    Class host = NSClassFromString(@"AllTrails.AllTrailsHostURLParser");
    if (app) { %init(AllTrailsDelegates, ATAppDelegate = app); }
    if (factory) { %init(ParserFactory, ATParserFactory = factory); }
    if (host) { %init(HostParser, ATHostParser = host); }
}
