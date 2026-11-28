# Parano1d Wallet identity

Installed display name: Parano1d Wallet.
Bundle ID: com.koajent.parano1d.wallet.
AppIcon is selected explicitly in the generated Xcode build settings.

The 1024px icon is rendered from `Docs/AppIconSource.svg`. Its ring, numeral
path, strokes and green gradient colors come from the bundled upstream Parano1d
`Vendor/paramo1d/android/app/src/main/assets/brand.svg`. The near-black background fills
the square; there is no drawn rounded app tile or second thin ring. Build 52
reduces the ring to a radius of 76 with a 20-unit stroke and shifts the numeral
six units right for optical centering. iOS supplies
the final icon mask. The PNG is opaque RGB.

The shared in-app `Brand` image is rendered from `Docs/InAppBrand.svg` at
512 pixels with transparent corners and no outer dark disc. Its ring and numeral
use the same centered proportions. Welcome, lock, Home asset, and title
components all reference that one image. Tab and action icons use iOS system symbols.

This configures the app launcher icon, not a WidgetKit Home Screen widget.
A separate widget extension has not been implemented. No balances are exposed
on the lock screen or in a widget by this change.
