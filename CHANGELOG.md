# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Documentation and help aligned with 0.3.0 behavior (keys, dpkg prerequisite, quit-with-pending, Updater field).
- Exit summary reports pending work as `install/update` and `remove`.
- Removed unused full-screen process-result helper (output lives in Recent Operations).

## [0.3.0] - 2026-08-04

### Added

- Package **update** detection for installed deb-get packages (`Installed` vs `Published`, via `dpkg --compare-versions`).
- Session-only `update_available` flags; passive Recent Operations hint: `updates are available. Press u to mark all updates`.
- **`u`**: scan installed packages (cache missing or ≥ 24 hours old), progress `scanning n of m for updates`, mark updates as **`[↑]`** / `marked for update:`.
- **Esc** during update scan cancels remaining fetches and keeps partial marks.
- Space on installed packages: clear update mark first, then toggle remove (remove wins over update).
- Apply path reports **`updated:`** for upgrades vs **`installed:`** for new installs.
- Chunked package-details loading (startup and on scroll): at most **5** network `deb-get show` calls per burst; disk cache rehydrate for warm entries.
- Multi-package `deb-get show` parse/batch helpers for efficient detail fetch.

### Changed

- Browse still uses a **7-day** details cache TTL; **`u`** uses a **24-hour** refresh threshold for installed packages only.
- Recent Operations staging order: updates, then installs, then removes.
- README documents updates workflow, markers, and cache behavior; version **0.3.0**.

## [0.2.0] - 2026-08-04

### Added

- Fixed mid-screen **Recent Operations** pane for mark staging and apply progress.
- **Space** / **c** / **f** keybindings; fetch cooldown (30s; startup counts as a fetch).
- Mark staging for install/remove; **Enter** applies all marks.
- Sudo password collection in Recent Operations (masked) when elevation is required.
- Exit summary after terminal restore; reliable terminal restore and atexit cleanup.
- Private temp files for deb-get output capture (avoid fixed world-writable paths).
- List viewport fill down to the status bar; `.gitignore` (drop tracked binary).

### Changed

- UX polish and safer operations around apply and terminal handling.
- Version **0.2.0**.

## [0.1.0] - earlier

### Added

- Initial TUI for deb-get: available package list, package details pane, install/remove via deb-get.
- On-disk package details cache under `~/.cache/debtui/` with cleanup of stale/unknown packages.
- Basic keyboard navigation and marking workflow (evolved through early commits).

[Unreleased]: https://github.com/scottdd/debtui/compare/main...HEAD
[0.3.0]: https://github.com/scottdd/debtui/commits/main
[0.2.0]: https://github.com/scottdd/debtui/commits/main
