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

    // AllTrails web links may contain a locale prefix such as /en-gb/.
    // Branch's deep-link path is kept locale-free so the app router sees the
    // actual content route rather than the website localisation route.
    if (parts.count >= 4 &&
        ATLooksLikeLocale(parts[1]) &&
        [parts[2].lowercaseString isEqualToString:@"trail"]) {

        NSMutableArray<NSString *> *clean = [parts mutableCopy];
        [clean removeObjectAtIndex:1];
        path = [clean componentsJoinedByString:@"/"];
    }

    return path;
}

static NSURL *ATNormalizedWebURL(NSURL *url) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!components) return url;

    components.scheme = @"https";
    components.host = @"www.alltrails.com";
    components.fragment = nil;
    return components.URL ?: url;
}

static NSString *ATDeepLinkPath(NSURL *url) {
    NSString *path = ATCanonicalPath(url);
    while ([path hasPrefix:@"/"]) {
        path = [path substringFromIndex:1];
    }
    return path;
}

static NSURL *ATBranchURL(NSURL *webURL) {
    NSURL *normalized = ATNormalizedWebURL(webURL);
    NSString *absolute = normalized.absoluteString ?: webURL.absoluteString ?: @"";
    NSString *deepPath = ATDeepLinkPath(normalized);

    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"https";
    components.host = @"alltrails.app.link";
    components.path = @"/";

    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];

    // AllTrails uses Branch for app-link handoff. Give Branch both the real
    // website URL and a locale-free deep-link path so AllTrails receives the
    // same kind of payload its own share links are designed around.
    if (absolute.length) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"$canonical_url" value:absolute]];
        [items addObject:[NSURLQueryItem queryItemWithName:@"$fallback_url" value:absolute]];
        [items addObject:[NSURLQueryItem queryItemWithName:@"$desktop_url" value:absolute]];
        [items addObject:[NSURLQueryItem queryItemWithName:@"url" value:absolute]];
    }

    if (deepPath.length) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"$deeplink_path" value:deepPath]];
        [items addObject:[NSURLQueryItem queryItemWithName:@"deeplink_path" value:deepPath]];
        [items addObject:[NSURLQueryItem queryItemWithName:@"path" value:deepPath]];
    }

    NSURLComponents *source = [NSURLComponents componentsWithURL:normalized resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in source.queryItems ?: @[]) {
        if ([item.name isEqualToString:@"sh"] && item.value.length) {
            [items addObject:[NSURLQueryItem queryItemWithName:@"sh" value:item.value]];
            break;
        }
    }

    [items addObject:[NSURLQueryItem queryItemWithName:@"~feature" value:@"share"]];
    [items addObject:[NSURLQueryItem queryItemWithName:@"~channel" value:@"alltrails_virality"]];
    components.queryItems = items;

    return components.URL ?: normalized;
}

static NSURL *ATDirectDeepLinkURL(NSURL *webURL) {
    NSString *path = ATDeepLinkPath(webURL);
    if (!path.length) return [NSURL URLWithString:@"alltrails://"];

    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"alltrails";

    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count > 0) {
        components.host = parts.firstObject;
        if (parts.count > 1) {
            components.path = [@"/" stringByAppendingString:[[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"/"]];
        }
    }

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

    NSURL *branchURL = ATBranchURL(url);
    NSMutableDictionary *branchOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
    branchOptions[UIApplicationOpenURLOptionUniversalLinksOnly] = @YES;

    void (^wrappedCompletion)(BOOL) = ^(BOOL success) {
        if (success) {
            if (completion) completion(YES);
            return;
        }

        // If Branch universal-link handoff itself is unavailable, retain the
        // direct custom-scheme route as a last-resort launcher.
        NSURL *deepLinkURL = ATDirectDeepLinkURL(url);
        NSMutableDictionary *deepLinkOptions = options ? [options mutableCopy] : [NSMutableDictionary dictionary];
        [deepLinkOptions removeObjectForKey:UIApplicationOpenURLOptionUniversalLinksOnly];

        [self openURL:deepLinkURL
              options:deepLinkOptions
    completionHandler:^(BOOL deepLinkSuccess) {
            if (completion) completion(deepLinkSuccess);
        }];
    };

    %orig(branchURL, branchOptions, wrappedCompletion);
}

- (BOOL)openURL:(NSURL *)url {
    if (!ATIsAllTrailsWebURL(url)) {
        return %orig;
    }

    NSURL *branchURL = ATBranchURL(url);
    return %orig(branchURL);
}

%end
