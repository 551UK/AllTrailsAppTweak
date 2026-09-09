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

    // Preserve the original AllTrails share path and query parameters.
    // In particular, do not remove /en-gb or the share token before iOS asks
    // AllTrails to handle the universal link.
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

    // Mirror the web route directly into the AllTrails custom scheme.
    // Example:
    //   https://www.alltrails.com/en-gb/trail/england/cumbria/foo
    // becomes:
    //   alltrails://trail/england/cumbria/foo
    //
    // The previous alltrails://screen/trail/... form launched AllTrails but
    // resolved to its "Content unavailable" page.
    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"alltrails";

    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count > 0) {
        components.host = parts.firstObject;
        if (parts.count > 1) {
            components.path = [@"/" stringByAppendingString:[[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"/"]];
        }
    }

    // Keep AllTrails' own share parameters in case the installed version uses
    // them to resolve the shared trail.
    components.query = webURL.query;
    return components.URL ?: [NSURL URLWithString:@"alltrails://"];
}

static void ATOpenAllTrailsURL(UIApplication *application,
                               NSURL *url,
                               NSDictionary<UIApplicationOpenExternalURLOptionsKey, id> *options,
                               void (^completion)(BOOL)) {
    NSURL *universalURL = ATUniversalLinkURL(url);
    NSMutableDictionary *universalOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
    universalOptions[UIApplicationOpenURLOptionUniversalLinksOnly] = @YES;

    [application openURL:universalURL
                 options:universalOptions
       completionHandler:^(BOOL success) {
        if (success) {
            if (completion) completion(YES);
            return;
        }

        NSURL *deepLinkURL = ATDirectDeepLinkURL(universalURL);
        NSMutableDictionary *deepLinkOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
        [deepLinkOptions removeObjectForKey:UIApplicationOpenURLOptionUniversalLinksOnly];

        [application openURL:deepLinkURL
                     options:deepLinkOptions
           completionHandler:^(BOOL deepLinkSuccess) {
            if (completion) completion(deepLinkSuccess);
        }];
    }];
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

        // deepLinkURL uses the alltrails:// scheme, so it will not re-enter
        // the AllTrails-web-URL branch of this hook.
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

    // Do not force legacy callers straight into a custom scheme. Route them
    // through the same universal-link-first path used by the modern API.
    ATOpenAllTrailsURL(self, url, nil, nil);
    return YES;
}

%end
