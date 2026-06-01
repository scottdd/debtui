# debtui

A terminal user interface (TUI) front-end for [deb-get](https://github.com/wimpysworld/deb-get).

## Features

- Browse all packages available through deb-get in a single scrollable list (left pane)
- View detailed information for the currently selected package (right pane)
- Mark packages directly for installation (`i`) or uninstallation (`u`) from the main list
- Apply all marked operations at once with `Enter`
- Reset all marks with `r`
- Real-time throbber in the status bar while operations are running

## Background

I am learning Odin, and plan to build a fleet of TUI apps. I chose this as my first project because deb-get could do the hard work and I could learn some of the tricks of the Odin trade. This tool scratches an itch I had using deb-get, and I hope it helps you, too.

## Prerequisites

- [Odin compiler](https://odin-lang.org/docs/install/)
- [deb-get](https://github.com/wimpysworld/deb-get) installed and available in `$PATH`
- A modern terminal that supports ANSI escape codes and the alternate screen buffer

## Build & Run

```bash
# Build
odin build src -out:debtui -o:speed

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
| `i`     | Mark selected package for **installation**       |
| `u`     | Mark selected package for **uninstallation**     |
| `Enter` | Apply all marked install and uninstall operations |
| `r`     | Clear all pending marks                          |

### Other
| Key       | Action                                   |
|-----------|------------------------------------------|
| `q` / `Q` | Quit                                     |
| `R`       | Refresh package lists from deb-get       |
| `?`       | Show keybindings in the status bar       |
| `Ctrl+C`  | Force quit                               |

## Interface

- **Left pane**: Scrollable list of available packages.
  - `[i]` = already installed via deb-get
  - `[+]` = marked for installation
  - `[-]` = marked for uninstallation
- **Right pane**: Detailed information about the currently selected package.
- **Status bar**: Shows pending operations and a throbber (`| / - \`) while packages are being installed or removed.

## Screenshots

(Screenshots coming soon)

## How It Works

`debtui` uses `deb-get` under the hood:

- `deb-get list --raw` — populates the main list
- `deb-get list --installed` — determines which packages are already installed
- `deb-get show <pkg>` — fetches details for the right pane (cached locally for 7 days)
- On **Enter**: runs `deb-get install ...` and/or `deb-get remove ...` for all marked packages

Package details are cached on disk to avoid repeated network requests. See the **Persistent Cache** section for details.

All package operations are performed only when you explicitly press `Enter`.

## Persistent Cache

`debtui` maintains an on-disk cache of package details to reduce repeated calls to deb-get and GitHub.

- **Location**: `~/.cache/debtui/` (or `$XDG_CACHE_HOME/debtui` if set)
- **TTL**: Package details are considered fresh for 7 days.
- **Automatic cleanup**: On startup and every manual refresh (`R`), the app removes:
  - Entries older than 7 days
  - Entries for packages that no longer appear in `deb-get list --raw`
- **Diagnostic logs**: If cache-related errors occur, they are written to daily files named `cache-errors-YYYY-MM-DD.log` inside the cache directory. These files are only created when something noteworthy happens.

This caching makes browsing large lists of packages much faster after the first run.

## License

This project is released into the public domain under the [Unlicense](LICENSE).

## Author

[ScottDD](https://github.com/scottdd)

**Repository:** https://github.com/scottdd/debtui

## Contributing

Bug reports and pull requests are welcome. Please try to keep the interface simple and keyboard-driven.
