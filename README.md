# AllTrailsLinkFix

Fixes shared AllTrails trail links on rootless iOS 16 so tapping a trail URL opens the exact trail directly inside AllTrails instead of only launching the app.

Built specifically for the supplied **AllTrails 23.2.40** build. The tweak carries the complete shared web URL into AllTrails and hands it to the app's native website-link parser, so long regional/share links open the correct trail.

Install the DEB and respring. If you use Choicy, allow **AllTrailsLinkFix** in both the app you open links from and AllTrails.

Built for arm64 and arm64e.

This tweak only fixes link routing; it does not unlock app features.
