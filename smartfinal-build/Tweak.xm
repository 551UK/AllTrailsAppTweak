#import <Foundation/Foundation.h>

@interface RNDeviceInfo : NSObject
- (NSString *)getAppVersion;
- (NSString *)getBuildNumber;
- (NSDictionary *)constantsToExport;
@end

@interface FIRRemoteConfigValue : NSObject
- (instancetype)initWithData:(NSData *)data source:(NSInteger)source;
@end

@interface FIRRemoteConfig : NSObject
- (id)configValueForKey:(NSString *)key;
- (id)configValueForKey:(NSString *)key source:(NSInteger)source;
- (id)objectForKeyedSubscript:(NSString *)key;
@end

static NSString * const SFTargetBundle = @"com.mercatustechnologies.smartfinal";
static NSString * const SFSpoofVersion = @"26.32.1";
static NSString * const SFSpoofBuild = @"2147483647";

static BOOL SFIsTargetMainBundle(NSBundle *bundle) {
    return bundle == [NSBundle mainBundle] || [[bundle bundleIdentifier] isEqualToString:SFTargetBundle];
}

static BOOL SFVersionRemoteKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    NSString *k = [key lowercaseString];
    return [k isEqualToString:@"forceupdateversion"] ||
           [k isEqualToString:@"softupdateversion"] ||
           [k hasSuffix:@".forceupdateversion"] ||
           [k hasSuffix:@".softupdateversion"];
}

static BOOL SFBoolRemoteKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]]) return NO;
    NSString *k = [key lowercaseString];
    return [k isEqualToString:@"forceupdate"] ||
           [k isEqualToString:@"isforceupdate"] ||
           [k hasSuffix:@".forceupdate"] ||
           [k hasSuffix:@".isforceupdate"];
}

static id SFFakeRemoteValue(NSString *value) {
    Class cls = NSClassFromString(@"FIRRemoteConfigValue");
    if (!cls) return nil;
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    return [[cls alloc] initWithData:data source:0];
}

%hook NSBundle

- (id)objectForInfoDictionaryKey:(NSString *)key {
    if (SFIsTargetMainBundle(self)) {
        if ([key isEqualToString:@"CFBundleShortVersionString"]) return SFSpoofVersion;
        if ([key isEqualToString:@"CFBundleVersion"]) return SFSpoofBuild;
    }
    return %orig;
}

- (NSDictionary *)infoDictionary {
    NSDictionary *original = %orig;
    if (!SFIsTargetMainBundle(self) || !original) return original;

    NSMutableDictionary *patched = [original mutableCopy];
    patched[@"CFBundleShortVersionString"] = SFSpoofVersion;
    patched[@"CFBundleVersion"] = SFSpoofBuild;
    return patched;
}

%end

%hook RNDeviceInfo

- (NSString *)getAppVersion {
    return SFSpoofVersion;
}

- (NSString *)getBuildNumber {
    return SFSpoofBuild;
}

- (NSDictionary *)constantsToExport {
    NSDictionary *original = %orig;
    NSMutableDictionary *patched = original ? [original mutableCopy] : [NSMutableDictionary dictionary];
    patched[@"appVersion"] = SFSpoofVersion;
    patched[@"buildNumber"] = SFSpoofBuild;
    patched[@"version"] = SFSpoofVersion;
    return patched;
}

%end

%hook FIRRemoteConfig

- (id)configValueForKey:(NSString *)key {
    if (SFVersionRemoteKey(key)) {
        id value = SFFakeRemoteValue(@"0.0.0");
        if (value) return value;
    }
    if (SFBoolRemoteKey(key)) {
        id value = SFFakeRemoteValue(@"false");
        if (value) return value;
    }
    return %orig;
}

- (id)configValueForKey:(NSString *)key source:(NSInteger)source {
    if (SFVersionRemoteKey(key)) {
        id value = SFFakeRemoteValue(@"0.0.0");
        if (value) return value;
    }
    if (SFBoolRemoteKey(key)) {
        id value = SFFakeRemoteValue(@"false");
        if (value) return value;
    }
    return %orig;
}

- (id)objectForKeyedSubscript:(NSString *)key {
    if (SFVersionRemoteKey(key)) {
        id value = SFFakeRemoteValue(@"0.0.0");
        if (value) return value;
    }
    if (SFBoolRemoteKey(key)) {
        id value = SFFakeRemoteValue(@"false");
        if (value) return value;
    }
    return %orig;
}

%end

%ctor {
    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:SFTargetBundle]) {
        NSLog(@"[SmartFinalUpdateBypass] loaded; spoofing version %@ build %@", SFSpoofVersion, SFSpoofBuild);
    }
}
