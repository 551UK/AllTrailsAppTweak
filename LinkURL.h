#import <Foundation/Foundation.h>

// Transport the URL in the launch itself: no shared state or guessed trail IDs.
static NSURL *ATCanonicalTrailURL(NSURL *url) {
    if (!url || url.absoluteString.length > 16384) return nil;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *scheme = c.scheme.lowercaseString;
    NSString *host = c.host.lowercaseString;
    if (!([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) ||
        !([host isEqualToString:@"alltrails.com"] || [host isEqualToString:@"www.alltrails.com"]) ||
        c.user.length || c.password.length || c.port) return nil;
    NSMutableArray<NSString *> *parts = [[c.percentEncodedPath componentsSeparatedByString:@"/"] mutableCopy];
    if (parts.count && !parts[0].length) [parts removeObjectAtIndex:0];
    if (parts.count && !parts.lastObject.length) [parts removeLastObject];
    if (parts.count > 1 && [parts[1] isEqualToString:@"trail"] &&
        [parts[0] rangeOfString:@"^[A-Za-z]{2}(-[A-Za-z]{2})?$" options:NSRegularExpressionSearch].location != NSNotFound) {
        [parts removeObjectAtIndex:0];
    }
    if (parts.count < 4 || ![parts[0] isEqualToString:@"trail"]) return nil;
    for (NSString *part in parts) {
        NSString *decoded = part.stringByRemovingPercentEncoding;
        if (!decoded.length || [decoded isEqualToString:@"."] || [decoded isEqualToString:@".."] ||
            [decoded containsString:@"/"] || [decoded containsString:@"\\"]) return nil;
    }
    c.scheme = @"https";
    c.host = @"www.alltrails.com";
    c.percentEncodedPath = [@"/" stringByAppendingString:[parts componentsJoinedByString:@"/"]];
    return c.URL;
}

static NSURL *ATTransportURL(NSURL *url) {
    NSURL *canonical = ATCanonicalTrailURL(url);
    if (!canonical) return nil;
    NSURLComponents *c = [NSURLComponents new];
    c.scheme = @"alltrails";
    c.host = @"551-open";
    c.queryItems = @[[NSURLQueryItem queryItemWithName:@"url" value:canonical.absoluteString]];
    return c.URL;
}

static NSURL *ATIncomingURL(NSURL *url) {
    if (!url) return nil;
    NSURL *canonical = ATCanonicalTrailURL(url);
    if (canonical) return canonical;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (![c.scheme.lowercaseString isEqualToString:@"alltrails"]) return url;
    if ([c.host.lowercaseString isEqualToString:@"551-open"]) {
        NSArray *items = c.queryItems;
        if (items.count == 1 && [items[0] name] && [[items[0] name] isEqualToString:@"url"]) {
            NSURL *result = ATCanonicalTrailURL([NSURL URLWithString:[items[0] value]]);
            if (result) return result;
        }
        return url;
    }
    // Repair earlier scheme-only rewrites, while preserving native trail/<numeric ID> links.
    NSString *host = c.host.lowercaseString;
    if ([host isEqualToString:@"www.alltrails.com"] || [host isEqualToString:@"alltrails.com"]) {
        c.scheme = @"https";
    } else if ([host isEqualToString:@"trail"] ||
               [host rangeOfString:@"^[a-z]{2}(-[a-z]{2})?$" options:NSRegularExpressionSearch].location != NSNotFound) {
        c.percentEncodedPath = [NSString stringWithFormat:@"/%@%@", host, c.percentEncodedPath ?: @""];
        c.scheme = @"https";
        c.host = @"www.alltrails.com";
    } else return url;
    return ATCanonicalTrailURL(c.URL) ?: url;
}
