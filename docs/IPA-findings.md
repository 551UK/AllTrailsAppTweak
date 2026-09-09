# AllTrails 25.2.40 link inspection

The supplied file was named `AllTrails _23.2.40.ipa`, but Info.plist reports version 25.2.40, build 86784, minimum iOS 16.0 and bundle ID com.alltrails.AllTrails. The executable is unencrypted (LC_ENCRYPTION_INFO_64 cryptid=0).

Executable SHA-256: b095617f1ee0e8799377e1320a781dfee71a6e783a7ee6df4d81ea3aeebccb5d.

## Evidence from the executable

Addresses below are unslid static addresses for this IPA only. The tweak does not patch addresses or machine code.

- SceneDelegate implements `scene:willConnectToSession:options:`, `scene:openURLContexts:` (0x10092c2bc), and `scene:continueUserActivity:` (0x10092c360).
- The warm URL handler reads the actual UIOpenURLContext.URL property (0x10092e17c), then calls its own handle routine (0x10092ceb8). That routine delegates to DeepLinkParametersService and checks startup processing state before continuing.
- DeepLinkURLParserFactory `parserForURL:` (0x100d2ba50, Swift body 0x100d2bb68) selects separate parsers for the alltrails scheme and the alltrails.com host.
- AllTrailsSchemeURLParser `featureForURL:source:completion:` is exposed to Objective-C at 0x100af9754. Its trail route (0x100b06184) uses a helper at 0x100afef18 which reads pathComponents[1] and parses a base-10 integer. A country name in that position is not a trail ID.
- AllTrailsHostURLParser `featureForURL:source:completion:` is exposed at 0x10074b884. Its trail handler (0x10074c280) derives a slug from the full path and calls `retrieveRemoteTrailWithSlug:completion:` at 0x10074c60c. Thus the geographic path must be preserved; a title-only search is unnecessary for routing.
- Startup log strings explicitly say deep links must first be handled by DeepLinkStep to avoid races with CoreData and other services.

## Version 2.0 behavior

Outgoing website trail links become `alltrails://551-open?url=<percent-encoded canonical website URL>`. The actual URL travels in the launch request, including query parameters and fragment. No Darwin notification state, clipboard, file handoff, or UI search automation is used.

Inside AllTrails the real incoming context URL is decoded before the original scene code reads it. Both cold and warm launch paths keep their original context objects and options. NSUserActivity and the app delegate URL entry point also normalize links. Factory and host-parser entry points normalize consistently. Optional language prefixes are removed so the route begins with `/trail/`; country, region and trail slug remain intact. Native numeric-ID scheme links and unrelated links remain intact.

The previous files are removed from the build. They are recoverable in git history.

## Verification and limits

Foundation tests cover the supplied URL, percent-encoding, query/fragment retention, repeated normalization, old scheme rewrites, native numeric links and unrelated hosts. CI builds/signs the rootless arm64/arm64e package and validates its Debian metadata and payload.

Static inspection establishes parser expectations; it cannot establish current server responses or successful device navigation. Test the supplied WhatsApp/ChatGPT link with AllTrails terminated, already open and in the background. Confirm the actual trail detail page opens and that repeating the same link works. Choicy must allow this tweak in source and destination apps. If another URL-rewriting tweak intercepts first, its behavior can affect delivery.

Apple's scene lifecycle reference: https://developer.apple.com/documentation/uikit/uiscenedelegate/scene(_:openurlcontexts:)
