#import "../LinkURL.h"
#include <stdlib.h>
static int checks;
static void check(BOOL ok, const char *message) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
int main(void) { @autoreleasepool {
    NSString *shared = @"https://www.alltrails.com/en-gb/trail/england/cumbria/fletchers-wood-colwith-force-and-cathedral-quarry-circular?p=-1&sh=nn6y54&u=i&utm_medium=trail_share&utm_source=alltrails_virality";
    NSString *expected = [shared stringByReplacingOccurrencesOfString:@"/en-gb/" withString:@"/"];
    NSURL *url = [NSURL URLWithString:shared];
    NSURL *transport = ATTransportURL(url);
    check([transport.scheme isEqualToString:@"alltrails"], "Launch targets AllTrails");
    check([ATIncomingURL(transport).absoluteString isEqualToString:expected], "Exact shared trail survives launch transport");
    check([ATIncomingURL(ATIncomingURL(transport)).absoluteString isEqualToString:expected], "Receiver is idempotent");
    NSArray *trails = @[
        @"http://alltrails.com/trail/england/cumbria/a-trail/",
        @"https://www.alltrails.com/de/trail/germany/bayern/gr%C3%BCner-weg?q=a%26b%3Dc#photos",
        @"https://www.alltrails.com/trail/france/ile-de-france/a%2520b?x=one+two&x=three",
        @"https://www.alltrails.com/EN-GB/trail/england/cumbria/a-trail"
    ];
    for (NSString *s in trails) {
        NSURL *u = [NSURL URLWithString:s];
        check([ATIncomingURL(ATTransportURL(u)) isEqual:ATCanonicalTrailURL(u)], "Encoded URL round trip");
    }
    NSArray *unrelated = @[@"https://example.com/trail/england/cumbria/foo", @"https://alltrails.com.evil.com/trail/a/b/c", @"https://notalltrails.com/trail/a/b/c", @"https://www.alltrails.com/members/me", @"https://www.alltrails.com/trail", @"alltrails://trail/12345", @"alltrails://screen/recorder?start=true", @"fb18128749820at://authorize", @"https://www.alltrails.com/trail/a/b%2Fc/d", @"https://user@alltrails.com/trail/a/b/c"];
    for (NSString *s in unrelated) check(ATTransportURL([NSURL URLWithString:s]) == nil, "Unrelated URLs are not intercepted");
    check([ATIncomingURL([NSURL URLWithString:@"alltrails://trail/12345"]).absoluteString isEqualToString:@"alltrails://trail/12345"], "Native numeric trail link preserved");
    check([ATIncomingURL([NSURL URLWithString:@"alltrails://trail/england/cumbria/a-trail"]).absoluteString isEqualToString:@"https://www.alltrails.com/trail/england/cumbria/a-trail"], "Old scheme-only rewrite repaired");
    check([ATIncomingURL([NSURL URLWithString:@"alltrails://en-gb/trail/england/cumbria/a-trail"]).absoluteString isEqualToString:@"https://www.alltrails.com/trail/england/cumbria/a-trail"], "Old localized scheme rewrite repaired");
    NSURL *bad = [NSURL URLWithString:@"alltrails://551-open?url=https%3A%2F%2Fevil.com%2Ftrail%2Fa%2Fb%2Fc"];
    check([ATIncomingURL(bad) isEqual:bad], "Transport cannot route arbitrary hosts");
    NSLog(@"Passed %d URL routing checks", checks);
} return 0; }
