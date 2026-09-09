# AllTrailsAppTweak

AllTrails hiking app companion tweak for older/rootless iOS setups.

This tweak fixes newer AllTrails share links that older AllTrails versions may send to Safari instead of opening in the app. It removes newer locale prefixes such as `/en-gb/`, tries the canonical AllTrails universal link first, and falls back to the older `alltrails://screen/...` deep-link router.

Designed for Dopamine/rootless iOS 15+.
