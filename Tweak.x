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

    // Modern AllTrails share URLs often look like:
    // /en-gb/trail/england/...
    // Older app versions expect the canonical form:
    // /trail/england/...
    if (parts.count >= 4 &&
        ATLooksLikeLocale(parts[1]) &&
        [parts[2].lowercaseString isEqualToString:@"trail"]) {

        NSMutableArray<NSString *> *clean = [parts mutableCopy];
        [clean removeObjectAtIndex:1];
        path = [clean componentsJoinedByString:@"/"];
    }

    return path;
}

static NSURL *ATCanonicalWebURL(NSURL *url) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) return url;

    components.scheme = @"https";
    components.host = @"www.alltrails.com";
    components.path = ATCanonicalPath(url);

    // The path identifies the trail. Removing share/tracking parameters gives
    // older AllTrails versions the simplest URL to parse.
    components.query = nil;
    components.fragment = nil;

    return components.URL ?: url;
}

static NSURL *ATLegacyDeepLinkURL(NSURL *canonicalURL) {
    NSString *path = canonicalURL.path ?: @"";
    while ([path hasPrefix:@"/"]) {
        path = [path substringFromIndex:1];
    }

    if (!path.length) return [NSURL URLWithString:@"alltrails://"];

    // Older AllTrails builds used alltrails://screen/... routes.
    NSString *deepLink = [@"alltrails://screen/" stringByAppendingString:path];
    return [NSURL URLWithString:deepLink];
}

%hook UIApplication

- (void)openURL:(NSURL *)url
        options:(NSDictionary<UIApplicationOpenExternalURLOptionsKey, id> *)options
completionHandler:(void (^)(BOOL success))completion {

    if (!ATIsAllTrailsWebURL(url)) {
        %orig;
        return;
    }

    NSURL *canonicalURL = ATCanonicalWebURL(url);
    NSMutableDictionary *universalOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
    universalOptions[UIApplicationOpenURLOptionUniversalLinksOnly] = @YES;

    void (^wrappedCompletion)(BOOL) = ^(BOOL success) {
        if (success) {
            if (completion) completion(YES);
            return;
        }

        // If the old app no longer participates in the current universal-link
        // association, fall back to AllTrails' legacy custom URL router.
        NSURL *legacyURL = ATLegacyDeepLinkURL(canonicalURL);
        NSMutableDictionary *legacyOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
        [legacyOptions removeObjectForKey:UIApplicationOpenURLOptionUniversalLinksOnly];

        [self openURL:legacyURL
              options:legacyOptions
    completionHandler:^(BOOL legacySuccess) {
            if (completion) completion(legacySuccess);
        }];
    };

    %orig(canonicalURL, universalOptions, wrappedCompletion);
}

- (BOOL)openURL:(NSURL *)url {
    if (!ATIsAllTrailsWebURL(url)) {
        return %orig;
    }

    NSURL *canonicalURL = ATCanonicalWebURL(url);
    NSURL *legacyURL = ATLegacyDeepLinkURL(canonicalURL);

    // Apps still using the deprecated synchronous API cannot request
    // UniversalLinksOnly with a completion callback, so use the old AllTrails
    // deep-link route directly.
    return %orig(legacyURL);
}

%end
