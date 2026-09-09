# AllTrailsLinkFix

Fixes shared AllTrails trail links on rootless iOS 16 so tapping a trail URL opens the exact trail directly inside AllTrails instead of only launching the app.

Built specifically for the **premium-unlocked AllTrails 23.2.40 IPA** this project was tested against. The tweak carries the complete shared web URL into AllTrails and hands it to the app's native website-link parser, so long regional/share links open the correct trail.

The matching **AllTrails 23.2.40 IPA will also be placed in GitHub Releases alongside the DEB** so the tweak and the exact app build it was made for are kept together.

Install the DEB and respring. If you use Choicy, allow **AllTrailsLinkFix** in both the app you open links from and AllTrails.

Built for arm64 and arm64e.

The tweak itself only fixes link routing; the premium features are part of the matching IPA, not this tweak.
