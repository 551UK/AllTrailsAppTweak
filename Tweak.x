#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

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

static BOOL ATLooksLikeLocale(NSString *segment) {
    if (!segment.length) return NO;

    NSString *lower = segment.lowercaseString;
    if (lower.length == 2) return YES;

    if (lower.length == 5 && [lower characterAtIndex:2] == '-') {
        NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
        return [letters characterIsMember:[lower characterAtIndex:0]] &&
               [letters characterIsMember:[lower characterAtIndex:1]] &&
               [letters characterIsMember:[lower characterAtIndex:3]] &&
               [letters characterIsMember:[lower characterAtIndex:4]];
    }

    return NO;
}

static NSString *ATCanonicalPath(NSURL *url) {
    NSString *path = url.path ?: @"/";
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];

    // Modern share URLs can use /en-gb/trail/... while the older custom
    // router expects /trail/.... Keep locale handling only for the custom
    // scheme fallback; the universal-link attempt uses the exact share URL.
    if (parts.count >= 4 &&
        ATLooksLikeLocale(parts[1]) &&
        [parts[2].lowercaseString isEqualToString:@"trail"]) {

        NSMutableArray<NSString *> *clean = [parts mutableCopy];
        [clean removeObjectAtIndex:1];
        path = [clean componentsJoinedByString:@"/"];
    }

    return path;
}

static NSURL *ATUniversalLinkURL(NSURL *url) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) return url;

    // Keep the exact share path and query. The previous build stripped the
    // locale and share token before asking iOS to hand the URL to AllTrails,
    // which can make older app/AASA combinations reject the link.
    components.scheme = @"https";
    if ([components.host.lowercaseString isEqualToString:@"alltrails.com"]) {
        components.host = @"www.alltrails.com";
    }
    components.fragment = nil;

    return components.URL ?: url;
}

static NSURL *ATDirectDeepLinkURL(NSURL *webURL) {
    NSString *path = ATCanonicalPath(webURL);
    while ([path hasPrefix:@"/"]) {
        path = [path substringFromIndex:1];
    }

    if (!path.length) return [NSURL URLWithString:@"alltrails://"];

    // Mirror the canonical web route directly into the app scheme.
    // Example:
    //   https://www.alltrails.com/en-gb/trail/england/cumbria/foo
    // becomes:
    //   alltrails://trail/england/cumbria/foo
    //
    // The old alltrails://screen/trail/... fallback launched AllTrails but
    // landed on its "Content unavailable" screen.
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"alltrails";

    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count > 0) {
        components.host = parts.firstObject;
        if (parts.count > 1) {
            components.path = [@"/" stringByAppendingString:[[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"/"]];
        }
    }

    // Preserve AllTrails' share parameters in case this installed version
    // uses the share token while resolving the trail.
    components.query = webURL.query;
    return components.URL ?: [NSURL URLWithString:@"alltrails://"];
}

%hook UIApplication

- (void)openURL:(NSURL *)url
        options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey, id> *)options
completionHandler:(void (^)(BOOL success))completion {

    if (!ATIsAllTrailsWebURL(url)) {
        %orig;
        return;
    }

    NSURL *universalURL = ATUniversalLinkURL(url);
    NSMutableDictionary *universalOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
    universalOptions[UIApplicationOpenURLOptionUniversalLinksOnly] = @YES;

    void (^wrappedCompletion)(BOOL) = ^(BOOL success) {
        if (success) {
            if (completion) completion(YES);
            return;
        }

        NSURL *deepLinkURL = ATDirectDeepLinkURL(universalURL);
        NSMutableDictionary *deepLinkOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
        [deepLinkOptions removeObjectForKey:UIApplicationOpenURLOptionUniversalLinksOnly];

        // This is now an alltrails:// URL, so it bypasses the web-URL branch
        // of this hook and goes straight to the original implementation.
        [self openURL:deepLinkURL
              options:deepLinkOptions
    completionHandler:^(BOOL deepLinkSuccess) {
            if (completion) completion(deepLinkSuccess);
        }];
    };

    %orig(universalURL, universalOptions, wrappedCompletion);
}

- (BOOL)openURL:(NSURL *)url {
    if (!ATIsAllTrailsWebURL(url)) {
        return %orig;
    }

    // The deprecated synchronous API cannot supply UniversalLinksOnly plus a
    // completion handler. Use the corrected direct scheme route rather than
    // the broken alltrails://screen/... form.
    NSURL *deepLinkURL = ATDirectDeepLinkURL(ATUniversalLinkURL(url));
    return %orig(deepLinkURL);
}

%end
