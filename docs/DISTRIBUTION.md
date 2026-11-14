# LucidSQL Distribution & Packaging Guide

## Supported Platforms & Appearance

- **Architecture:** Apple Silicon (`arm64`) only. Intel (`x86_64`) builds are not produced.
- **Deployment Target:** macOS 14.0 (Sonoma) or later (`LSMinimumSystemVersion = 14.0`, SwiftPM `.macOS(.v14)`).
- **Build Toolchain & Liquid Glass:** Release builds must be compiled with **Xcode 26+ / macOS 26+ SDK** (Swift 6.2+) so that the macOS 26+ Liquid Glass UI (`NSGlassEffectView`, `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`, `.glassEffect`) is compiled into the binary. Fallback styling (`.bordered`, `.borderedProminent`, `.ultraThinMaterial`, `VisualEffectBackground`) remains active at runtime on macOS 14–15.

## Signing & Gatekeeper Model

LucidSQL is distributed directly via GitHub Releases as an **ad-hoc signed, unnotarized** `.app` inside a `.dmg` (no paid Apple Developer membership or notarization secrets required).

Because downloaded builds are unnotarized, macOS Gatekeeper will block the first launch of a downloaded copy. Users should use the standard per-app macOS flow:

1. Open `LucidSQL-<version>-macos-arm64.dmg` and drag `LucidSQL.app` into `Applications`.
2. Attempt to open `LucidSQL.app` once and dismiss the Gatekeeper warning.
3. Open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway** next to LucidSQL.
4. Click **Open** to confirm.

Do **not** globally disable Gatekeeper (`spctl --master-disable`).

## Local Build, Packaging & Verification

Both local builds and GitHub Actions use the shared scripts in `scripts/`:

```bash
# 1. Build Rust core, generate UniFFI bridge, and run Rust + Swift tests
./tests/bridge_smoke_test.sh

# 2. Build release .app bundle, rewrite Mach-O linkage, sign ad-hoc inside-out,
#    and package versioned arm64 DMG + SHA-256 checksum
./scripts/package-app.sh \
  --skip-bridge-build \
  --configuration release \
  --signing-mode adhoc \
  --dmg \
  --require-liquid-glass \
  --version 0.1.0 \
  --output-dir App/.build/dist

# 3. Verify the DMG end-to-end (mounts DMG, copies .app outside repo, hides build
#    directories, checks Mach-O linkage/codesign/Liquid Glass, launches relocated app)
./scripts/verify-dmg.sh \
  --require-liquid-glass \
  --isolate-repo-build-dirs \
  App/.build/dist/LucidSQL-0.1.0-macos-arm64.dmg
```

## CI & Release Automation

- **Pushes / PRs to `main`:** Runs on `macos-26` (Apple Silicon arm64, macOS 26+ SDK), runs full Rust + Swift tests against disposable PostgreSQL 16, builds and verifies the development DMG, and uploads `LucidSQL-dev-macos-arm64-dmg` as a workflow artifact without publishing a release.
- **Manual builds:** Trigger **macOS CI & Release** via GitHub Actions `workflow_dispatch` (leave `publish_release` unchecked for a build artifact only, or check `publish_release` with an explicit `version` to publish a release).
- **Version tags (`v*`):** Pushing a tag such as `v0.1.0` builds, tests, verifies, and publishes `LucidSQL-0.1.0-macos-arm64.dmg` and `LucidSQL-0.1.0-macos-arm64.dmg.sha256` to GitHub Releases. Tags containing `-` (e.g. `v0.1.0-rc.1`) are automatically marked as prereleases.
