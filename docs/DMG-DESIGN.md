# DMG installer artwork

The installer uses a 720 × 272 point Finder content area, with 128 point icons
centered at (145, 130) and (560, 130). The pale background is `#F7FBFE`.
The text transitions from graphite `#313740` to mist blue `#6F8B9D`; the rounded
smile arrow is `#607D91`. The application, Applications shortcut, and their labels
are real Finder items. The background contains only the instruction and arrow.

`Resources/Installer` contains the reviewed 1×/2× background PNGs and a silver
drive icon with the application's waveform. The ICNS sets the mounted volume's
icon; downloaded DMG files may use the system disk-image icon. Finder supplies
window controls, shortcut badges, and file labels, which can vary by macOS settings.

## Package

Install Node.js 24, then run from the repository root:

```sh
npm ci --prefix scripts/dmg
./scripts/build-app.sh release
./scripts/package-release.sh
```

The tooling pins [create-dmg 8.1.0](https://github.com/sindresorhus/create-dmg)
and its appdmg engine. The stock create-dmg CLI was evaluated during design, but
does not expose custom background/layout options. `scripts/dmg/create-installer.mjs`
uses appdmg directly to apply the approved assets. It generates an APFS image
compressed with LZFSE, and appdmg combines the two background sizes into a Retina TIFF.
The DMG retains README and MIT license files in the hidden `.Documentation`
folder; the alternative ZIP includes them at its root. Packaging does not change
the app's signature or add notarization.

## Edit the artwork

`scripts/render-dmg-assets.py` is the editable artwork source. Regeneration is
optional and requires macOS, Python 3, and Pillow. Release jobs consume the
checked-in assets and do not install Pillow:

```sh
python3 scripts/render-dmg-assets.py
```

Verify a generated image with `hdiutil verify`, then mount it read-only to check
the background TIFF, Finder layout, volume icon, Applications link, documentation,
version, executable architecture, and app signature before publishing.
