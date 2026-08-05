# debtui

A terminal user interface (TUI) front-end for [deb-get](https://github.com/wimpysworld/deb-get).

## Features

- Browse all packages available through deb-get in a single scrollable list (left pane)
- View detailed information for the currently selected package (right pane)
- Toggle install/remove/update marks with `Space` (context-aware; press again to unmark)
- Scan installed packages for updates with `u` and mark them for upgrade
- Passive notice in Recent Operations when an update is discovered while loading details
- Apply all marked operations at once with `Enter` (installs, updates, removes)
- Clear all marks with `c`; re-fetch package lists with `f` (rate limited)
- **Recent Operations** pane (fixed mid-screen header) shows staging and apply results
- In-app help (`?`) uses the full right column (details + Recent Operations); RO returns when help is closed
- Quit with pending marks prompts to apply them first (timeout defaults to leave pending)

## Background

This application is clanker code. I am learning Odin, and plan to build a fleet of TUI apps. I chose this as my first project because deb-get could do the hard work and I could learn some of the tricks of the Odin trade. This tool scratches an itch I had using deb-get, and I hope it helps you, too. 

## Prerequisites

- **Linux** (termios / ANSI alternate screen)
- [Odin compiler](https://odin-lang.org/docs/install/)
- [deb-get](https://github.com/wimpysworld/deb-get) installed and available in `$PATH`
- **`dpkg`** (for version compares when detecting package updates; standard on Debian/Ubuntu)
- A modern terminal that supports ANSI escape codes and the alternate screen buffer

## Build & Run

**Build from source only.** Do not run prebuilt binaries from untrusted sources.

```bash
# Build
odin build src -out:debtui -o:speed

# Or with the project script (enables -vet)
./build.sh

# Run
./debtui
```

Or run directly:

```bash
odin run src
```

### CLI Flags

| Flag           | Description                                      |
|----------------|--------------------------------------------------|
| `--version`    | Print version and exit                           |
| `--verbose`, `-v` | Enable detailed diagnostic logging (useful when reporting bugs) |

Example:

```bash
./debtui --version
./debtui --verbose     # or -v
```

## Key Bindings

### Navigation
| Key           | Action                                      |
|---------------|---------------------------------------------|
| `↑` / `k`     | Move selection up                           |
| `↓` / `j`     | Move selection down                         |
| `PgUp` / `PgDn` | Scroll by page                            |
| `Home` / `End`  | Jump to first / last item                 |

### Marking & Actions
| Key     | Action                                           |
|---------|--------------------------------------------------|
| `Space` | **Toggle mark** — not installed: install (press again to unmark); installed: clear update → remove → clear |
| `Enter` | Apply all marked install, update, and remove operations |
| `u`     | Scan installed packages for updates and mark them |
| `Esc`   | During an update scan: cancel remaining fetches (partial marks kept) |
| `c`     | Clear all pending marks                          |

### Other
| Key       | Action                                   |
|-----------|------------------------------------------|
| `f`       | Fetch package lists from deb-get (rate limited: 30s cooldown) |
| `?`       | Toggle full-height help on the right (hides Recent Operations until closed) |
| `q` / `Q` | Quit (if marks are pending, prompt to apply first) |
| `Ctrl+C`  | Quit (same as `q`)                       |
| `Ctrl+R`  | Same as `f` (fetch, rate limited)        |

## Interface

- **Left pane**: Scrollable list of available packages.
  - `[i]` = already installed via deb-get
  - `[↑]` = marked for update (upgrade)
  - `[+]` = marked for installation
  - `[-]` = marked for uninstallation
- **Right pane (top)**: Detailed information about the currently selected package (above the selection row), including Updater, Installed, and Published when known. With **`?`**, help fills the entire right column (details + Recent Operations height).
- **Recent Operations**: Fixed mid-screen header (hidden while help is open; restored when help is dismissed). While staging: `marked for update/installation/removal: pkg` (list rebuilds on unmark). Passive discovery may show `updates are available. Press u to mark all updates`. During **`u`**: `scanning n of m for updates`. After **Enter**: optional **sudo password** prompt (masked), then apply progress (`updated:`, `installed:`, `removed:`, failures). Other notes (fetch, cooldown) also appear here.
- **Status bar**: Key hints only (changes during password entry or quit-with-pending prompt).

## How It Works

`debtui` uses `deb-get` under the hood:

- `deb-get list --raw` — populates the main list
- `deb-get list --installed` — determines which packages are already installed
- `deb-get show <pkg list>` — fetches details for the right pane (cached locally for 7 days)
- On **Enter**: runs `deb-get install ...` (new installs and upgrades) and/or `deb-get remove ...` for all marked packages

After the package list loads (startup or **f**), `debtui` rehydrates fresh disk-cache entries into memory, then fetches at most **5** missing/expired detail entries via `deb-get show` (so startup stays responsive). Gaps load over time: when you focus a package that still needs details, it fetches that package plus up to four more gaps further down the list. If more than four packages are fetched in one burst, Recent Operations briefly shows `loading details: n/m`.

### Updates

- Only **installed** packages are considered for updates (deb-get list scope, not full-system apt).
- A package has an update when `show` reports a non-empty **Published** version newer than **Installed** (`dpkg --compare-versions`), typically for `Updater: deb-get`. Empty Published means unknown, not “up to date.”
- While loading details, if an update is discovered, Recent Operations may show a one-time hint: `updates are available. Press u to mark all updates`.
- **`u`** re-fetches details for installed packages whose cache is **missing or ≥ 24 hours** old (chunks of 5; Esc cancels remaining fetches and keeps partial marks). It then marks every known update except packages already marked for removal. Marks show as **`[↑]`** and `marked for update: pkg`.
- **`c`** clears all marks (including updates). If updates are still known from the current session cache, the hint can appear again.
- Known-update flags are **in-memory for the session only** (not stored as a separate cache flag).

Package details are cached on disk to avoid repeated network requests. See the **Persistent Cache** section for details.

All package operations are performed only when you explicitly press `Enter` (or confirm apply when quitting with pending marks).

## Persistent Cache

`debtui` maintains an on-disk cache of package details to reduce repeated calls to deb-get and GitHub.

- **Location**: `~/.cache/debtui/` (or `$XDG_CACHE_HOME/debtui` if set)
- **TTL**: Package details are considered fresh for **7 days** during normal browse/preload.
- **Update scan (`u`)**: Uses a **24-hour** threshold for installed packages only; successful fetches refresh the same cache files (`cached_at`).
- **Startup / fetch preload**: After listing packages, fresh cache files are loaded into memory; at most 5 missing/expired entries are fetched over the network. Further gaps load over time (on focus, 5 at a time) or when you run **`u`** for installed packages.
- **Automatic cleanup**: On startup and every list fetch (`f`), the app removes:
  - Entries older than 7 days
  - Entries for packages that no longer appear in `deb-get list --raw`
- **Diagnostic logs**: If cache-related errors occur, they are written to daily files named `cache-errors-YYYY-MM-DD.log` inside the cache directory. These files are only created when something noteworthy happens.

This caching makes browsing large lists of packages much faster after the first run as gaps load over time / on focus / via `u`.

## License

This project is released into the public domain under the [Unlicense](LICENSE).

## Author

[ScottDD](https://github.com/scottdd)

**Repository:** https://github.com/scottdd/debtui

## Contributing

Bug reports and pull requests are welcome. Please try to keep the interface simple and keyboard-driven.

See [CHANGELOG.md](CHANGELOG.md) for version history.
