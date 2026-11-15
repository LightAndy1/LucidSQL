# LucidSQL

A fast, native macOS PostgreSQL client built with **SwiftUI / AppKit** and a **Rust** (`tokio-postgres`) core. Designed for developers and database engineers who want quick schema navigation, responsive spreadsheet-style table browsing, and safe, transparent editing without Electron overhead.

<p align="center">
  <img src="Assets/Screenshots/lucidsql-workspace.png" alt="LucidSQL workspace showing schema sidebar, orders table grid, and non-SQL Search table bar" width="900">
</p>

## Core Features

- **Connection Profiles & Security:** Save connection profiles locally, import `postgres://` / `postgresql://` URLs, configure TLS (`disable`, `prefer`, `require`, `verify-ca`, `verify-full` with optional root CA), and store passwords in macOS Keychain.
- **Fast Schema & Table Browsing:** Tree-based schema/table sidebar with quick table filtering, row counts, and a virtualized `NSTableView` data grid for responsive scrolling and keyboard navigation.
- **Non-SQL Table Search & Pagination:** Press `⌘F` inside Table Data to run case-insensitive literal matching across all searchable columns or a single column, paired with a compact pagination popover (`25` / `50` / `100` / `250` / `500` rows per page and Go-to-Page).
- **Safe In-Grid Editing:** Stage cell edits, row inserts, and row deletes locally in memory with distinct `NULL` (`⌥⌘N`) vs. empty string `""` handling. Review a pre-commit diff before changes apply atomically inside a transaction with `xmin` conflict detection.
- **Dual-Enforced Read-Only Mode:** One-click toolbar toggle disables UI mutations while enforcing `SET default_transaction_read_only = on` and `BEGIN READ ONLY` in the Rust core.
- **Dedicated-Session SQL Editor:** Multi-tab syntax-highlighted SQL editor (`⌘↩` to run query or selection) where each tab holds its own persistent PostgreSQL connection to preserve temporary tables, `search_path`, and transaction state, with live query cancellation and close-tab rollback warnings.
- **Snapshot CSV Export:** RFC 4180 CSV export for the current page or all rows streamed inside a `REPEATABLE READ READ ONLY` transaction snapshot.

---

## Requirements & Appearance

- **Architecture:** Apple Silicon (`arm64`) Macs only.
- **Operating System:** **macOS 14.0 (Sonoma)** or later.
- **Visual Appearance:**
  - On **macOS 26 (Tahoe)** and later (when built with Xcode 26+ SDK), LucidSQL renders native **Liquid Glass** toolbar surfaces, glass button styles, and layered native app icon appearances.
  - On **macOS 14–15** (and when *Reduce Transparency* is enabled), the interface automatically falls back to standard `.ultraThinMaterial` / `.bordered` AppKit & SwiftUI controls and the bundled `.icns` icon.

---

## Download & Installation

> **Release Status:** No public GitHub Release has been published yet. Once tagged releases are published, signed DMGs and `.sha256` checksums will be available on the [GitHub Releases](https://github.com/LightAndy1/LucidSQL/releases) page. Until then, you can download CI build artifacts from [GitHub Actions](https://github.com/LightAndy1/LucidSQL/actions) or build a local development DMG from source below.

1. Download the `.dmg` archive (and optionally verify its checksum with `shasum -a 256 -c LucidSQL-*.dmg.sha256`).
2. Open the `.dmg` and drag **`LucidSQL.app`** into **`Applications`**.
3. **First-Launch Gatekeeper Note:** Released builds are **intentionally ad-hoc signed and unnotarized** (not Developer ID notarized). On first launch, macOS Gatekeeper will warn that the app cannot be verified:
   1. Attempt to open **LucidSQL** once from Finder or Applications, then dismiss the prompt.
   2. Open **System Settings → Privacy & Security**, scroll to the **Security** section, and click **Open Anyway** next to LucidSQL.
   3. Confirm **Open Anyway** when prompted.

---

## Building from Source

### Prerequisites

- Apple Silicon Mac (`arm64`)
- [Rust toolchain](https://rustup.rs/) (`cargo`)
- Swift toolchain via Xcode Command Line Tools, or **Xcode 26+** for full Liquid Glass SDK symbols and compiled native `Assets.car` layered app icon variants
- Optional: local PostgreSQL (`postgresql@16`) to run live database integration tests

### Common Commands

```bash
# Build the Rust core and regenerate UniFFI Swift bindings
./scripts/build-rust-bridge.sh

# Run Rust and Swift unit tests + bridge smoke verification
./tests/bridge_smoke_test.sh

# Package and launch a local debug bundle
./scripts/run-app.sh

# Build a release ad-hoc .app and distributable .dmg + .sha256
./scripts/package-app.sh --configuration release --signing-mode adhoc --dmg

# Verify relocated DMG integrity, Mach-O linkage, signing, and isolated launch
./scripts/verify-dmg.sh --isolate-repo-build-dirs App/.build/LucidSQL-*.dmg
```

Pass `--require-liquid-glass --require-native-icon` to `package-app.sh` and `verify-dmg.sh` when building with Xcode 26+ (see [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) for full packaging and release notes).

---

## Privacy & Local Storage

LucidSQL collects **no telemetry, crash reports, or analytics**, and makes no network connections other than direct PostgreSQL connections you initiate.

- **Saved Connection Profiles:** Stored locally at `~/Library/Application Support/LucidSQL/profiles.json` (never includes passwords).
- **Passwords:** Stored strictly in the **macOS Keychain** (`com.lucidsql.connection-passwords`) when *Remember password* is enabled, or kept in memory for the current session only.
- **SQL Drafts:** Optionally persisted locally at `~/Library/Application Support/LucidSQL/sql_drafts.json` (can be disabled in Settings; preference stored via `UserDefaults`).

---

## Current Limitations

- **Apple Silicon (`arm64`) only:** Intel (`x86_64`) builds are not provided or supported.
- **Direct TCP/TLS connections only:** Built-in SSH tunneling, multi-host failover connection strings, and Unix-socket `postgres://` URLs are not supported.
- **Table Search scope:** Non-SQL table search (`⌘F`) matches searchable scalar columns and skips binary, JSON, array, geometric, and range columns.
- **SQL Results & Export:** SQL editor results display up to `1,000` rows by default. CSV export always reads committed database rows (unstaged grid edits are excluded) and writes raw cell values.
- **CommandLineTools-only builds:** Packaging without full Xcode skips `actool` compilation of `Assets/AppIcon/LucidSQL.icon` into `Assets.car` and uses the fallback `LucidSQL.icns`.

---

## License

LucidSQL is licensed under the **GNU Affero General Public License v3.0** (`AGPL-3.0-only`). See [LICENSE](LICENSE) for full terms.
