# Repository guide

## Project and license

- Meeting Intelligence is a native macOS 26+ app with Swift 6.2+ sources, a read-only `meeting` CLI, and a bundled Rust summary backend.
- This project uses the MIT license in `LICENSE`. Preserve its copyright and permission notice when distributing source or binaries; third-party dependencies retain their own licenses.
- Public GitHub repository: `https://github.com/wdtte/Meeting-Intelligence`. The existing `origin` remote points to GitLab; use the `github` remote explicitly for GitHub pushes.
- Keep `README.md`, `AGENTS.md`, and `LICENSE` at the root. Put other project Markdown documents under `docs/`. Keep public README instructions in English and Simplified Chinese consistent.

## Build and verify

```sh
./scripts/test.sh
cargo test --locked --manifest-path Helpers/summary/Cargo.toml
./scripts/build-app.sh release
./scripts/package-release.sh
```

- Build on macOS with the macOS 26 SDK or newer and Swift 6.2+. Install stable Rust with the native macOS target.
- Reuse the existing scripts; the app bundle must contain `MeetingIntelligence`, `meeting`, `meeting-summary`, the app icon, and transcript export resources.
- Use synthetic audio, temporary directories, and mocked network services in tests. Do not record real meetings or call paid providers in routine checks.
- Never commit API keys, signing credentials, recordings, transcripts, or build output. API keys belong in macOS Keychain.

## Automatic GitHub releases

- Workflow: `.github/workflows/release.yml`. Pushing any tag to GitHub builds and publishes a Release for that tag. The Release workflow also supports manual dual-architecture validation on a branch without publishing. `.github/workflows/ci.yml` runs Swift/Rust tests on Intel for `main` pushes and pull requests, without release compilation or packaging.
- Ordinary CI cancels superseded runs per branch/PR; release runs are grouped by ref and tags are never automatically cancelled.
- `.github/actions/setup-build/action.yml` pins Rust 1.99.1 and caches `.build`, Cargo registry/git, and Rust target outputs. Keys isolate OS, architecture, actual Xcode/SDK/Swift/Rust versions, and dependency manifests; commit suffixes and restore prefixes refresh caches across source changes. Credentials, app bundles, and `dist/` are excluded. Debug tests and native-target release builds retain separate compiler outputs. Caching does not remove runner queue time.
- `scripts/ci-timing-summary.py` adds queue and step durations to the job summary; timing API failures do not fail a build.
- The build matrix uses `macos-26` for Apple Silicon (`arm64`) and `macos-26-intel` for Intel (`x86_64`). Each job runs Swift and Rust tests, builds the app, and uploads an architecture-specific ZIP and SHA-256 checksum.
- `scripts/package-release.sh` packages the signed app, README, and MIT license. Release assets are named `Meeting-Intelligence-X.Y.Z-macos-ARCH.zip` and `.zip.sha256`. These are separate native builds, not a universal binary.
- Version tags should use `vX.Y.Z` (for example `v0.2.4`). Tags such as `v0.2.4-rc.1` publish a prerelease. The numeric version is injected into the built app through `MEETING_APP_VERSION`; `MEETING_BUILD_NUMBER` uses the Actions run number. Other tag names still publish a Release and retain the version from `Resources/Info.plist`.
- The publish job waits for both architectures, verifies checksums, generates release notes, uploads all assets to a draft, and publishes it. Failed builds do not publish a Release. Rerunning a tag workflow updates assets on the same Release.
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

4. Check GitHub Actions and the Release page for both architecture ZIPs and checksums.

Only create or push a release tag when the user requests a release. Do not rewrite an existing published version tag. If a build fails, fix the underlying problem and use a new version tag, or rerun the same tag when only an external service was unavailable.
