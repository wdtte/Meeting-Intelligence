# Repository guide

## Project and license

- Meeting Intelligence is a native macOS app (standard: 26+; Whisper compatibility: 15+) with Swift 6.2+ sources, a read-only `meeting` CLI, and a bundled Rust summary backend.
- This project uses the MIT license in `LICENSE`. Preserve its copyright and permission notice when distributing source or binaries; third-party dependencies retain their own licenses.
- Public GitHub repository: `https://github.com/wdtte/Meeting-Intelligence`. The existing `origin` remote points to GitLab; use the `github` remote explicitly for GitHub pushes.
- Keep `README.md`, `AGENTS.md`, and `LICENSE` at the root. Put other project Markdown documents under `docs/`. Keep public README instructions in English and Simplified Chinese consistent.

## Build and verify

```sh
./scripts/test.sh
MEETING_BUILD_EDITION=compatibility ./scripts/test.sh
cargo test --locked --manifest-path Helpers/summary/Cargo.toml
./scripts/build-app.sh release
npm ci --prefix scripts/dmg
./scripts/package-release.sh
```

- Build on macOS with the macOS 26 SDK or newer and Swift 6.2+. Install stable Rust with the native macOS target.
- Build editions use `MEETING_BUILD_EDITION=standard` (default) or `compatibility`. Standard packages must never download or include Whisper backends/models. Compatibility builds require CMake 3.21+, fetch checksum-pinned dependencies from `Helpers/whisper/manifest.json`, and bundle Whisper with its licenses. Use separate Swift/Cargo build directories. See `docs/MACOS-15.md` for packaging and runtime checks. Keep the Bundle ID and data schema shared; do not relabel historical Apple segments as Whisper.
- Reuse the existing scripts; the app bundle must contain `MeetingIntelligence`, `meeting`, `meeting-summary`, the app icon, and transcript export resources.
- Use synthetic audio, temporary directories, and mocked network services in tests. Do not record real meetings or call paid providers in routine checks.
- Never commit API keys, signing credentials, recordings, transcripts, or build output. API keys belong in macOS Keychain.

## Automatic GitHub releases

- Workflow: `.github/workflows/release.yml`. Pushing any tag to GitHub builds and publishes a Release for that tag. The Release workflow also supports manual dual-architecture validation on a branch without publishing. `.github/workflows/ci.yml` runs Swift/Rust tests for both editions on Intel for `main` pushes and pull requests, without release compilation or packaging.
- Ordinary CI cancels superseded runs per branch/PR; release runs are grouped by ref and tags are never automatically cancelled.
- `.github/actions/setup-build/action.yml` uses `build-v3` keys isolated by edition and pins Rust 1.99.1 and caches `.build`, Cargo registry/git, and Rust target outputs. Keys isolate the cache profile (`test` by default, `release` for the Release workflow), OS, architecture, actual Xcode/SDK/Swift/Rust versions, and dependency manifests; commit suffixes and restore prefixes refresh caches across source changes. Separate profiles prevent a test-only job from filling an immutable cache key before Release outputs can be saved. Older `build-v2`/`build-v1` caches are fallback seeds only; successful jobs save under their new profile key. Credentials, app bundles, and `dist/` are excluded. Debug tests and native-target release builds retain separate compiler outputs. Caching does not remove runner queue time or guarantee that all compiler work can be skipped.
- Actions caches are scoped by ref: a new tag can restore compatible caches from the default branch, but cannot reuse a previous tag's private cache. To seed Release caches for future tags, manually run the Release workflow on `main` after the relevant changes land. This validates both architectures and saves Release caches on the default branch without publishing. A tag's own saved cache helps reruns of that tag. Do not add full release compilation to ordinary CI merely to warm caches.
- `scripts/ci-timing-summary.py` adds queue and step durations to the job summary; timing API failures do not fail a build.
- The build matrix uses `macos-26` for Apple Silicon (`arm64`) and `macos-26-intel` for Intel (`x86_64`). Each architecture builds both editions. Each job runs Swift and Rust tests, builds the app, and uploads an architecture-specific DMG, ZIP, and SHA-256 checksum for each format.
- `scripts/package-release.sh` packages the signed app, README, and MIT license. DMG packaging requires Node.js 24 and `npm ci --prefix scripts/dmg`; the Release workflow installs these separately from the Swift/Rust build cache. The pinned create-dmg/appdmg tooling uses the reviewed backgrounds and silver volume icon under `Resources/Installer`, with a 720×272 layout, graphite-to-mist-blue instruction text, and a `#607D91` smile arrow. The artwork source is `scripts/render-dmg-assets.py` (optional macOS/Pillow); see `docs/DMG-DESIGN.md`. The APFS/LZFSE DMG includes an Applications shortcut for drag-and-drop installation and README/LICENSE in hidden `.Documentation`; the ZIP provides an alternative archive. Release assets are named `Meeting-Intelligence-X.Y.Z-macos-ARCH.dmg`, `.zip`, and their `.sha256` files. Compatibility assets append `-macos15-whisper` before the extension; standard names stay unchanged. `scripts/verify-app.py` enforces deployment targets, signatures, system-only dynamic dependencies, and model/license isolation on builds and mounted DMGs. These are separate native builds, not a universal binary. The architecture is read from the app executable, so an existing release app can be repackaged on either host architecture. Optional arguments are the output directory and app path, in that order. Verify disk images with `hdiutil verify`; mount read-only to check the app, signature, version, architecture, resources, and Applications shortcut before publishing packaging changes. Changing the container does not add Developer ID signing or notarization.
- Version tags should use `vX.Y.Z` (for example `v0.2.4`). Tags such as `v0.2.4-rc.1` publish a prerelease. The numeric version is injected into the built app through `MEETING_APP_VERSION`; `MEETING_BUILD_NUMBER` uses the Actions run number. Other tag names still publish a Release and retain the version from `Resources/Info.plist`.
- The publish job waits for both editions on both architectures and macOS 15 CLI/Whisper synthetic-speech runtime validation, verifies checksums, generates release notes, uploads all assets to a draft, and publishes it. Failed builds do not publish a Release. Rerunning a tag workflow updates assets on the same Release.
- CI uses ad-hoc signing (`MEETING_CODESIGN_IDENTITY=-`); packages are not Developer ID signed or notarized. Do not describe them as Apple-notarized or silently remove macOS security attributes. Adding Developer ID signing/notarization requires a separate change and protected secrets.
- The default `GITHUB_TOKEN` is sufficient. Only the publish job has `contents: write`. Pin external actions to reviewed commit SHAs and pass tag names through environment variables, never by interpolating them directly into shell source.

### Publish a version

1. Update `Resources/Info.plist` when advancing the checked-in app version/build number. Update documentation and complete the checks above.
2. Commit the changes and push `main` to the GitHub remote. Wait for the build workflow to pass.
3. Create and push an annotated version tag:

   ```sh
   git push github main
   git tag -a v0.2.4 -m "Release v0.2.4"
   git push github v0.2.4
   ```

4. Check GitHub Actions and the Release page for both architecture DMGs, ZIPs, and checksums.

Only create or push a release tag when the user requests a release. Do not rewrite an existing published version tag. If a build fails, fix the underlying problem and use a new version tag, or rerun the same tag when only an external service was unavailable.
