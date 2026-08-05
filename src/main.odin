// This is free and unencumbered software released into the public domain.
// See the UNLICENSE file or https://unlicense.org/ for details.

package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:mem"
import "core:slice"
import "core:unicode/utf8"

// Set while the RO panel is collecting a sudo password (status bar hint changes).
password_entry_active := false

DEBTUI_VERSION :: "0.3.0"

// Global verbose flag controlled by --verbose / -v.
// When false, we suppress the detailed diagnostic logging that was added
// during the SIGSEGV investigation (load:, get_package_details:, draw:,
// detailed cleanup per-file lines, etc.). Real errors and important
// operational messages are still always logged.
verbose := false

// Scratch arena for one draw frame (padding strings, wrap lines, etc.).
// Avoids leaking heap allocations on every redraw.
draw_frame_backing: []byte
draw_frame_arena: mem.Arena

// ============================================================================
// debtui - TUI frontend for deb-get
//
// Layout (two panes):
//   +---------------------------+--------------------------------+
//   | LEFT: Available packages  | RIGHT: Package details         |
//   | (scrollable list)         | (upper half: fields / Help)    |
//   |                           | Recent Operations (mid-screen) |
//   |                           | operation log (below)          |
//   +---------------------------+--------------------------------+
//   | Status bar: key hints                                      |
//   +------------------------------------------------------------+
//
// Marking (left list only):
//   Space — not installed: toggle install mark;
//           installed: clear update → mark remove → clear remove.
//   u     — scan installed packages (cache missing/≥24h), mark known updates.
//   c     — clear all marks; re-hint if session still knows about updates.
//   Enter — apply pending installs/updates then removes (sudo via RO if needed).
//   Esc   — cancel remaining work during a long update scan (partial marks kept).
// Details pane follows left selection (or Help when show_help).
// ============================================================================

// Minimum seconds between user-initiated list fetches (f). Startup counts as a fetch.
FETCH_COOLDOWN_SECONDS :: 30

// Max packages to fetch via `deb-get show` in one burst (startup, scroll, or u).
DETAILS_FETCH_CHUNK :: 5

// Show a Recent Operations "loading details" line when fetching more than this many.
DETAILS_LOAD_MSG_THRESHOLD :: 4

// Passive RO nudge (shown at most once until cleared / after c with known updates).
UPDATES_HINT_MSG :: "updates are available. Press u to mark all updates"

// --------------------------- App State ---------------------------------------

App :: struct {
    // Data from deb-get
    available: []string,
    installed: []string,

    // Which packages are already installed (for quick lookup + markers in left list)
    installed_set: map[string]bool,

    // Pending actions (update marks reuse pending_install for installed packages)
    pending_install: map[string]bool,
    pending_remove:  map[string]bool,

    // Session-only: installed packages known to have a newer Published version
    update_available: map[string]bool,

    // Passive RO hint: show once until u/c/apply changes staging; after c may re-show
    updates_hint_shown: bool,

    // Left list (the only list) state
    left_selection:  int,
    left_scroll:     int,

    // In-memory package details (name → Package_Details); disk cache is separate
    details_cache: map[string]Package_Details,

    // Current rendered details for left selection
    current_details: Package_Details,

    // UI / terminal
    needs_redraw: bool,
    running:      bool,
    last_error:   string,      // for exit summary / rare failures (not status bar)
    show_help:    bool,        // right pane shows help instead of package details

    // Rate limit for f (Fetch list)
    last_fetch_unix: i64,

    // Recent Operations log (right column, below fixed mid-screen header)
    // Holds pending marks while staging, then apply results after Enter.
    status_lines:  [dynamic]string,
    status_scroll: int,

    // When true, draw() skips ensure_selection_details (avoids re-entrant fetch).
    skip_details_ensure: bool,
}

// --------------------------- List helpers ------------------------------------

// Center the selection in the viewport until we hit the top or bottom of the list.
// The selection "bar" stays near the middle; the list scrolls under it.
// Only near the very top or very bottom does the highlighted row move away from center.
recenter_list :: proc(selection, scroll: ^int, list_len: int, viewport_height: int) {
    if list_len == 0 {
        selection^ = 0
        scroll^ = 0
        return
    }

    if selection^ < 0 do selection^ = 0
    if selection^ >= list_len do selection^ = list_len - 1

    preferred := viewport_height / 2
    ideal_scroll := selection^ - preferred
    max_scroll := max(0, list_len - viewport_height)

    if ideal_scroll < 0 { ideal_scroll = 0 }
    if ideal_scroll > max_scroll { ideal_scroll = max_scroll }

    scroll^ = ideal_scroll
}

// Move selection by delta (up/down)
move_selection :: proc(selection, scroll: ^int, list_len: int, delta: int, viewport_height: int) {
    if list_len == 0 do return
    selection^ += delta
    recenter_list(selection, scroll, list_len, viewport_height)
}

// Page up / down
page_move :: proc(selection, scroll: ^int, list_len: int, direction: int, viewport_height: int) {
    if list_len == 0 do return
    delta := viewport_height - 1
    if direction < 0 do delta = -delta
    selection^ += delta
    recenter_list(selection, scroll, list_len, viewport_height)
}

// Jump to start or end
jump_to :: proc(selection, scroll: ^int, list_len: int, to_end: bool, viewport_height: int) {
    if list_len == 0 do return
    if to_end {
        selection^ = list_len - 1
    } else {
        selection^ = 0
    }
    recenter_list(selection, scroll, list_len, viewport_height)
}

// --------------------------- Drawing -----------------------------------------

// Colors used by the UI
COLOR_TITLE       :: Color.BrightCyan
COLOR_HEADER      :: Color.BrightWhite
COLOR_BORDER      :: Color.BrightBlack

// Selected line styling (per user request)
BG_SELECTED       :: BgColor.BrightCyan
COLOR_SELECTED    :: Color.BrightBlack   // medium grey on light cyan

COLOR_INSTALLED   :: Color.BrightGreen   // marker in left list
COLOR_PENDING_ADD :: Color.BrightGreen
COLOR_PENDING_RM  :: Color.BrightRed
COLOR_NORMAL      :: Color.White
COLOR_DIM         :: Color.BrightBlack
COLOR_STATUS_BG   :: BgColor.Blue
COLOR_STATUS_FG   :: Color.BrightWhite

// Base colors for the overall TUI (black bg + white text)
BASE_BG :: BgColor.Black
BASE_FG :: Color.White

// Details pane specific
DETAIL_BG :: BgColor.Black
DETAIL_FG :: Color.BrightWhite   // bright grey / light text on black for detail lines

// Draw a single list item with optional markers.
// Always writes exactly `width` columns so the pane looks solid.
// is_pending_update: installed + marked for upgrade (shown as [↑]).
draw_list_item :: proc(x, y, width: int, text: string, is_selected: bool, is_installed: bool, is_pending_install: bool, is_pending_remove: bool, is_pending_update: bool) {
    move_cursor(x, y)

    bg := BASE_BG
    text_fg := COLOR_NORMAL
    tag_fg := COLOR_NORMAL
    prefix := "  "

    if is_pending_update {
        tag_fg = COLOR_PENDING_ADD
        prefix = "[↑]"
    } else if is_pending_install {
        tag_fg = COLOR_PENDING_ADD
        prefix = "[+]"
    } else if is_pending_remove {
        tag_fg = COLOR_PENDING_RM
        prefix = "[-]"
    } else if is_installed {
        tag_fg = COLOR_INSTALLED
        prefix = "[i]"
    }

    if is_selected {
        bg = BG_SELECTED
        text_fg = COLOR_SELECTED
        // On the focused row, use a high-contrast bright color for the tag
        // so markers remain clearly visible against the cyan highlight.
        if prefix != "  " {
            tag_fg = COLOR_SELECTED
        }
    }

    set_bg(bg)

    tag_display := "   "   // normal (no marker) alignment: three columns
    tag_cols := 3
    if prefix != "  " {
        tag_display = strings.concatenate({" ", prefix, " "})
        tag_cols = utf8.rune_count_in_string(tag_display)
    }

    // Write the tag/marker portion in tag_fg (bright on focused row)
    set_fg(tag_fg)
    write(tag_display)

    // Write package name (possibly truncated) + padding in text color.
    // Use rune/column counts so multi-byte markers like [↑] stay aligned.
    set_fg(text_fg)
    name := text
    name_cols := utf8.rune_count_in_string(name)
    if tag_cols + name_cols > width {
        max_name := width - tag_cols - 1
        if max_name < 1 {
            max_name = 1
        }
        // Truncate by runes, then append ellipsis
        end := 0
        count := 0
        for r in name {
            if count >= max_name do break
            end += utf8.rune_size(r)
            count += 1
        }
        name = strings.concatenate({name[:end], "…"})
        name_cols = count + 1
    }

    write(name)

    written := tag_cols + name_cols
    remaining := width - written
    if remaining > 0 {
        spaces := strings.repeat(" ", remaining)
        write(spaces)
    }

    reset_attrs()
}

// Simple word wrapper for long text (e.g. Summary).
// Returns a slice of lines that fit within max_width.
wrap_text :: proc(text: string, max_width: int) -> []string {
    if max_width <= 0 {
        s := make([]string, 1)
        s[0] = strings.clone(text)
        return s
    }

    words := strings.split(text, " ")
    defer delete(words)

    lines: [dynamic]string
    current: strings.Builder
    strings.builder_init(&current)
    defer strings.builder_destroy(&current)

    for word in words {
        if len(word) > max_width {
            // Hard-wrap very long words
            if strings.builder_len(current) > 0 {
                append(&lines, strings.clone(strings.to_string(current)))
                strings.builder_reset(&current)
            }
            remaining := word
            for len(remaining) > 0 {
                chunk_len := min(len(remaining), max_width)
                append(&lines, strings.clone(remaining[:chunk_len]))
                remaining = remaining[chunk_len:]
            }
            continue
        }

        if strings.builder_len(current) == 0 {
            strings.write_string(&current, word)
        } else if strings.builder_len(current) + 1 + len(word) <= max_width {
            strings.write_string(&current, " ")
            strings.write_string(&current, word)
        } else {
            append(&lines, strings.clone(strings.to_string(current)))
            strings.builder_reset(&current)
            strings.write_string(&current, word)
        }
    }

    if strings.builder_len(current) > 0 {
        append(&lines, strings.clone(strings.to_string(current)))
    }

    return lines[:]
}

ensure_draw_frame_arena :: proc() {
    if draw_frame_backing == nil {
        draw_frame_backing = make([]byte, 1 * 1024 * 1024) // 1 MiB per frame
    }
}

// Fixed screen Y for the "Recent Operations" header: about halfway down the
// terminal, independent of list selection. Clamped so details + log still fit.
recent_ops_header_y :: proc(term_h, list_start_y: int) -> int {
    y := term_h / 2
    // Keep at least one detail row above when possible
    if y < list_start_y {
        y = list_start_y
    }
    // Leave room for at least one log row and the bottom status bar
    if y > term_h - 3 {
        y = max(list_start_y, term_h - 3)
    }
    return y
}

// Record / clear session update_available from details; optional passive RO hint.
note_package_update_status :: proc(app: ^App, pkg: string, d: Package_Details) {
    if !app.installed_set[pkg] {
        delete_key(&app.update_available, pkg)
        return
    }
    if package_has_update(d) {
        app.update_available[pkg] = true
        maybe_show_updates_hint(app)
    } else if strings.trim_space(d.published) != "" {
        // Definitive "have Published, not newer" → clear any prior flag
        delete_key(&app.update_available, pkg)
    }
    // Empty Published → unknown; leave existing flag alone
}

// Once-per-session (or after c resets the flag) RO nudge when we know updates exist.
maybe_show_updates_hint :: proc(app: ^App) {
    if len(app.update_available) == 0 do return
    if app.updates_hint_shown do return

    for line in app.status_lines {
        if line == UPDATES_HINT_MSG do return
    }
    append_status_line(app, UPDATES_HINT_MSG)
    app.updates_hint_shown = true
    app.needs_redraw = true
}

// Store batch results in details_cache (keys from available[] / need list).
apply_fetched_details :: proc(app: ^App, need: []string, fetched: []Package_Details) {
    for pkg in need {
        if _, already := app.details_cache[pkg]; already do continue
        found := false
        for d in fetched {
            if d.package_name == pkg {
                app.details_cache[pkg] = d
                note_package_update_status(app, pkg, d)
                found = true
                break
            }
        }
        if !found {
            app.details_cache[pkg] = Package_Details{
                package_name = pkg,
                raw = "Failed to fetch details from deb-get",
            }
        }
    }
}

// Fetch up to DETAILS_FETCH_CHUNK packages via deb-get show; optional RO progress.
fetch_details_chunk :: proc(app: ^App, need: []string) {
    if len(need) == 0 do return

    show_progress := len(need) > DETAILS_LOAD_MSG_THRESHOLD
    if show_progress {
        append_status_line(app, fmt.tprintf("loading details: 0/%d", len(need)))
        for pkg in need {
            if _, ok := app.details_cache[pkg]; !ok {
                app.details_cache[pkg] = Package_Details{
                    package_name = pkg,
                    title        = pkg,
                    summary      = "Loading package details…",
                }
            }
        }
        app.skip_details_ensure = true
        draw(app)
        app.skip_details_ensure = false
        for pkg in need {
            if d, ok := app.details_cache[pkg]; ok && d.summary == "Loading package details…" {
                delete_key(&app.details_cache, pkg)
            }
        }
    }

    fetched := fetch_package_details_batch(need)
    apply_fetched_details(app, need, fetched[:])
    delete(fetched)

    if show_progress {
        if len(app.status_lines) > 0 {
            last := app.status_lines[len(app.status_lines) - 1]
            if strings.has_prefix(last, "loading details") {
                delete(last)
                pop(&app.status_lines)
            }
        }
        app.needs_redraw = true
    }
}

// Collect up to `limit` packages that still need a network fetch, starting at
// start_idx and walking forward (wraps). Fresh disk hits are loaded into memory
// and do not count toward the limit.
collect_details_to_fetch :: proc(app: ^App, start_idx: int, limit: int) -> [dynamic]string {
    need := make([dynamic]string, 0, limit)
    n := len(app.available)
    if n == 0 || limit <= 0 do return need

    start := start_idx
    if start < 0 do start = 0
    if start >= n do start = 0

    for offset in 0..<n {
        if len(need) >= limit do break
        pkg := app.available[(start + offset) % n]
        if _, ok := app.details_cache[pkg]; ok do continue
        if details, ok := load_details_from_cache(pkg); ok {
            app.details_cache[pkg] = details
            note_package_update_status(app, pkg, details)
            continue
        }
        append(&need, pkg)
    }
    return need
}

// Ensure package details for the current selection use the permanent allocator
// (must run before switching context.allocator to the draw-frame arena).
// On cache miss/expired: fetch this package plus the next few missing ones (chunk).
ensure_selection_details :: proc(app: ^App) {
    if len(app.available) == 0 || app.left_selection >= len(app.available) {
        return
    }
    sel_pkg := app.available[app.left_selection]
    if verbose {
        log_cache_error(fmt.tprintf("draw: about to ensure details for current selection '%s'", sel_pkg))
    }
    if _, ok := app.details_cache[sel_pkg]; ok {
        return
    }
    // Try disk first (cheap); only burst-fetch when the focused package needs network.
    if details, ok := load_details_from_cache(sel_pkg); ok {
        app.details_cache[sel_pkg] = details
        note_package_update_status(app, sel_pkg, details)
        return
    }

    need := collect_details_to_fetch(app, app.left_selection, DETAILS_FETCH_CHUNK)
    defer delete(need)
    fetch_details_chunk(app, need[:])
}

// Main draw routine - called after every significant state change
draw :: proc(app: ^App) {
    clear_screen()
    reset_attrs()

    w := term_width
    h := term_height

    if (w < 60) || (h < 20) {
        move_cursor(2, 2)
        set_fg(Color.BrightRed)
        write("Terminal too small (need at least 60x20)")
        reset_attrs()
        return
    }

    // Layout calculations - two-pane layout
    left_width  := w * 45 / 100
    right_width := w - left_width - 1   // 1 for separator

    left_x  := 1
    right_x := left_width + 2

    header_y := 1
    list_start_y := 3

    // LEFT list viewport: rows from list_start_y through h-2 (status bar at h-1)
    // list_start_y=3 → height = h-2-3+1 = h-4
    left_viewport := h - 4
    recenter_list(&app.left_selection, &app.left_scroll, len(app.available), left_viewport)

    // Recent Operations header is fixed mid-screen (does not follow selection)
    ro_header_y := recent_ops_header_y(h, list_start_y)
    detail_y := list_start_y
    detail_h := max(0, ro_header_y - detail_y)
    status_region_y := ro_header_y
    status_portion_h := max(0, (h - 1) - status_region_y) // down to row above bottom status bar

    // Fetch details with permanent allocator before frame-local arena
    if !app.skip_details_ensure {
        ensure_selection_details(app)
    }

    // Frame arena: all padding / wrap allocations for this draw are freed when
    // we leave (arena reset next frame via re-init).
    ensure_draw_frame_arena()
    mem.arena_init(&draw_frame_arena, draw_frame_backing)
    prev_alloc := context.allocator
    context.allocator = mem.arena_allocator(&draw_frame_arena)
    defer context.allocator = prev_alloc

    // Establish base colors for the TUI (black background, white text)
    set_bg(BASE_BG)
    set_fg(BASE_FG)

    reset_attrs()
    set_bg(BASE_BG)
    set_fg(BASE_FG)

    // ---------------- Header ----------------
    set_fg(COLOR_TITLE)
    move_cursor(1,header_y)
    write(strings.repeat(" ", left_width+right_width))
    move_cursor(2,header_y)
    write("debtui")
    reset_attrs()

    move_cursor(left_x + 12, header_y)
    set_fg(COLOR_DIM)
    write("— deb-get TUI")
    reset_attrs()

    // ---------------- Left pane header ----------------
    move_cursor(left_x, list_start_y - 1)
    write(strings.repeat(" ", left_width))
    move_cursor(left_x, list_start_y - 1)
    set_fg(COLOR_HEADER)
    write("Available packages")
    if len(app.available) > 0 {
        writef(" (%d)", len(app.available))
    }
    reset_attrs()

    // ---------------- Details / Help column header ----------------
    move_cursor(right_x, list_start_y - 1)
    write(strings.repeat(" ", right_width))
    move_cursor(right_x, list_start_y - 1)
    set_fg(COLOR_HEADER)
    if app.show_help {
        write("Help")
    } else {
        write("Package details")
    }
    reset_attrs()

    // ---------------- Draw vertical separator (full height) ----------------
    draw_vline(left_width + 1, list_start_y - 1, h - 3, '│')

    // ---------------- LEFT: package list ----------------
    for i in 0..<left_viewport {
        idx := app.left_scroll + i
        y := list_start_y + i
        if y >= h - 1 do break

        if idx >= len(app.available) {
            move_cursor(left_x, y)
            set_bg(BASE_BG)
            set_fg(COLOR_DIM)
            write("~")
            if left_width > 1 {
                spaces := strings.repeat(" ", left_width-1)
                write(spaces)
            }
            reset_attrs()
            continue
        }

        pkg := app.available[idx]
        is_sel := (idx == app.left_selection)
        is_inst := app.installed_set[pkg]
        is_pend := app.pending_install[pkg]
        is_pend_rm := app.pending_remove[pkg]
        is_pend_upd := is_inst && is_pend && !is_pend_rm

        draw_list_item(left_x, y, left_width, pkg, is_sel, is_inst, is_pend && !is_pend_upd, is_pend_rm, is_pend_upd)
    }

    // ---------------- RIGHT: details above mid-screen; RO header fixed; log below ----------------

    // Blank the details portion
    for i in 0..<detail_h {
        move_cursor(right_x, detail_y + i)
        set_bg(DETAIL_BG)
        set_fg(DETAIL_FG)
        spaces := strings.repeat(" ", right_width)
        write(spaces)
        reset_attrs()
    }

    // Show help or package details (above Recent Operations)
    if detail_h > 0 && app.show_help {
        draw_help_pane(right_x, detail_y, right_width, detail_h)
    } else if detail_h > 0 && (len(app.available) > 0) && (app.left_selection < len(app.available)) {
        sel_pkg := app.available[app.left_selection]
        det := app.details_cache[sel_pkg]

        // Title line (keep cyan as requested) - wrap if extremely long
        move_cursor(right_x, detail_y)
        set_bg(DETAIL_BG)
        set_fg(Color.BrightCyan)
        title := det.title
        if title == "" do title = det.package_name
        if len(title) > right_width {
            title = title[:right_width]
        }
        write(title)
        title_pad := right_width - len(title)
        if title_pad > 0 {
            write(strings.repeat(" ", title_pad))
        }
        reset_attrs()

        // Key fields - wrap long values so nothing is chopped off
        fields := [?][2]string{
            {"Package",     det.package_name},
            {"Updater",     det.updater},
            {"Installed",   det.installed},
            {"Published",   det.published},
            {"Website",     det.website},
        }

        row := 1
        for field in fields {
            if row >= detail_h - 1 do break
            if field[1] == "" do continue

            key := field[0]
            value := field[1]
            prefix := strings.concatenate({key, ": "})
            prefix_len := len(prefix)
            avail := right_width - prefix_len

            if len(value) <= avail {
                // Fits on one line
                move_cursor(right_x, detail_y + row)
                set_bg(DETAIL_BG)
                set_fg(DETAIL_FG)
                write(prefix)
                write(value)
                pad := right_width - (prefix_len + len(value))
                if pad > 0 {
                    write(strings.repeat(" ", pad))
                }
                reset_attrs()
                row += 1
            } else {
                // Needs wrapping
                wrapped := wrap_text(value, avail)
                defer {
                    for line in wrapped { delete(line) }
                    delete(wrapped)
                }

                // First line with key
                move_cursor(right_x, detail_y + row)
                set_bg(DETAIL_BG)
                set_fg(DETAIL_FG)
                write(prefix)
                write(wrapped[0])
                pad := avail - len(wrapped[0])
                if pad > 0 {
                    write(strings.repeat(" ", pad))
                }
                reset_attrs()
                row += 1

                // Continuation lines (indented under the value)
                indent := strings.repeat(" ", prefix_len)
                for i := 1; i < len(wrapped); i += 1 {
                    if row >= detail_h - 1 do break
                    move_cursor(right_x, detail_y + row)
                    set_bg(DETAIL_BG)
                    set_fg(DETAIL_FG)
                    write(indent)
                    write(wrapped[i])
                    cont_pad := avail - len(wrapped[i])
                    if cont_pad > 0 {
                        write(strings.repeat(" ", cont_pad))
                    }
                    reset_attrs()
                    row += 1
                }
            }
        }

        // Summary with word wrapping (black bg + bright grey)
        if det.summary != "" && row < detail_h {
            prefix := "Summary: "
            prefix_len := len(prefix)
            first_line_width := right_width - prefix_len

            // Wrap the summary using the width available after the label for the first line
            wrapped := wrap_text(det.summary, first_line_width)
            defer {
                for line in wrapped { delete(line) }
                delete(wrapped)
            }

            // First line with label
            move_cursor(right_x, detail_y + row)
            set_bg(DETAIL_BG)
            set_fg(DETAIL_FG)
            write(prefix)
            if len(wrapped) > 0 {
                write(wrapped[0])
                pad := first_line_width - len(wrapped[0])
                if pad > 0 {
                    write(strings.repeat(" ", pad))
                }
            } else {
                write(strings.repeat(" ", first_line_width))
            }
            reset_attrs()
            row += 1

            // Continuation lines (use full right_width - indent)
            indent := strings.repeat(" ", prefix_len)
            cont_width := right_width - prefix_len
            for i := 1; i < len(wrapped); i += 1 {
                if row >= detail_h do break
                move_cursor(right_x, detail_y + row)
                set_bg(DETAIL_BG)
                set_fg(DETAIL_FG)
                write(indent)
                write(wrapped[i])
                pad := cont_width - len(wrapped[i])
                if pad > 0 {
                    write(strings.repeat(" ", pad))
                }
                reset_attrs()
                row += 1
            }
        }

        // Fallback raw output if no useful fields
        if (det.summary == "") && (det.raw != "") && (row < detail_h) {
            move_cursor(right_x, detail_y + row)
            set_bg(DETAIL_BG)
            set_fg(COLOR_DIM)
            preview := det.raw
            // Keep it reasonable and don't overflow the pane
            max_preview := right_width * 3
            if len(preview) > max_preview {
                preview = preview[:max_preview]
            }
            lines := strings.split_lines(preview)
            for &ln, li in lines {
                if li >= 3 || (row + li) >= detail_h do break
                move_cursor(right_x, detail_y + row + li)
                ln = strings.trim_space(ln)
                if len(ln) > right_width {
                    ln = ln[:right_width]
                }
                write(ln)
                pad := right_width - len(ln)
                if pad > 0 {
                    write(strings.repeat(" ", pad))
                }
            }
            reset_attrs()
        }
    } else if detail_h > 0 {
        move_cursor(right_x, detail_y)
        set_fg(COLOR_DIM)
        write("(no package selected)")
        reset_attrs()
    }

    // ---------------- Recent Operations (fixed mid-screen header) ----------------
    if status_portion_h > 0 {
        // Blank the status portion (header + log)
        for i in 0..<status_portion_h {
            move_cursor(right_x, status_region_y + i)
            set_bg(DETAIL_BG)
            set_fg(DETAIL_FG)
            spaces := strings.repeat(" ", right_width)
            write(spaces)
            reset_attrs()
        }

        // Header stays at fixed mid-screen row
        move_cursor(right_x, status_region_y)
        set_bg(DETAIL_BG)
        set_fg(COLOR_HEADER)
        header := "Recent Operations"
        write(header)
        if len(header) < right_width {
            pad := right_width - len(header)
            write(strings.repeat(" ", pad))
        }
        reset_attrs()

        // Log lines below the header
        status_view_h := status_portion_h - 1
        if status_view_h < 1 do status_view_h = 0

        max_scroll := max(0, len(app.status_lines) - status_view_h)
        if app.status_scroll > max_scroll do app.status_scroll = max_scroll
        if app.status_scroll < 0 do app.status_scroll = 0

        for i in 0..<status_view_h {
            idx := app.status_scroll + i
            y := status_region_y + 1 + i
            if y >= h - 1 do break
            if idx >= len(app.status_lines) {
                move_cursor(right_x, y)
                set_bg(DETAIL_BG)
                set_fg(DETAIL_FG)
                write(strings.repeat(" ", right_width))
                reset_attrs()
                continue
            }

            line := app.status_lines[idx]

            move_cursor(right_x, y)
            set_bg(DETAIL_BG)

            // Color by line kind
            action_color := COLOR_NORMAL
            if strings.has_prefix(line, "marked for installation:") ||
               strings.has_prefix(line, "marked for update:") ||
               strings.has_prefix(line, "installed:") ||
               strings.has_prefix(line, "updated:") {
                action_color = Color.BrightGreen
            } else if strings.has_prefix(line, "marked for removal:") ||
                      strings.has_prefix(line, "removed:") {
                action_color = Color.BrightRed
            } else if strings.has_prefix(line, "failed") {
                action_color = Color.BrightRed
            } else if strings.has_prefix(line, "fetch") ||
                      strings.has_prefix(line, "Fetched") ||
                      strings.has_prefix(line, "scanning ") ||
                      strings.has_prefix(line, "updates are available") ||
                      strings.has_prefix(line, "sudo") ||
                      strings.has_prefix(line, "password") {
                action_color = Color.BrightYellow
            }

            colon_idx := strings.index(line, ": ")
            if colon_idx >= 0 {
                action_part := line[:colon_idx+2]
                pkg_part := line[colon_idx+2:]

                total_needed := len(action_part) + len(pkg_part)
                if total_needed > right_width {
                    max_pkg := right_width - len(action_part) - 1
                    if max_pkg < 1 { max_pkg = 1 }
                    pkg_part = strings.concatenate({pkg_part[:max_pkg], "…"})
                }

                set_fg(action_color)
                write(action_part)
                set_fg(COLOR_NORMAL)
                write(pkg_part)

                written := len(action_part) + len(pkg_part)
                if written < right_width {
                    write(strings.repeat(" ", right_width - written))
                }
            } else {
                set_fg(action_color)
                txt := line
                if len(txt) > right_width {
                    txt = strings.concatenate({txt[:right_width-1], "…"})
                }
                write(txt)
                if len(txt) < right_width {
                    write(strings.repeat(" ", right_width - len(txt)))
                }
            }
            reset_attrs()
        }
    }

    // ---------------- Status bar (keys only) ----------------
    status_y := h - 1
    move_cursor(1, status_y)
    set_bg(COLOR_STATUS_BG)
    set_fg(COLOR_STATUS_FG)

    for _ in 0..<w do write(" ")
    move_cursor(1, status_y)

    if password_entry_active {
        write("sudo password  Enter: submit  Esc/Ctrl+C: cancel  (hidden in Recent Operations)")
    } else {
        write("↑↓/jk  Space: mark  Enter: apply  u: updates  c: clear  f: fetch  ?: help  q: quit")
    }

    reset_attrs()
}

// --------------------------- App Logic ---------------------------------------

init_app :: proc() -> App {
    app := App{
        running = true,
        needs_redraw = true,
        details_cache = make(map[string]Package_Details),
        installed_set     = make(map[string]bool),
        pending_install   = make(map[string]bool),
        pending_remove    = make(map[string]bool),
        update_available  = make(map[string]bool),
        status_lines      = make([dynamic]string),
    }
    return app
}

destroy_app :: proc(app: ^App) {
    delete(app.details_cache)
    delete(app.installed_set)
    delete(app.pending_install)
    delete(app.pending_remove)
    delete(app.update_available)
    for line in app.status_lines {
        delete(line)
    }
    delete(app.status_lines)
    if app.available != nil do delete(app.available)
    if app.installed != nil do delete(app.installed)
    if draw_frame_backing != nil {
        delete(draw_frame_backing)
        draw_frame_backing = nil
    }
}

// Load (or reload) data from deb-get
refresh_data :: proc(app: ^App) -> bool {
    app.last_error = ""

    avail, ok1 := get_available_packages()
    inst,  ok2 := get_installed_packages()

    if (!ok1) || (!ok2) {
        app.last_error = "Failed to query deb-get. Is it installed and working?"
        return false
    }

    // Replace data
    if app.available != nil do delete(app.available)
    if app.installed != nil do delete(app.installed)

    app.available = avail
    app.installed = inst

    // Rebuild installed set
    clear(&app.installed_set)
    for p in app.installed {
        app.installed_set[p] = true
    }

    // In-memory details keys pointed at the previous available[] strings; drop them.
    // Disk cache is the durable source of truth and is rehydrated by preload.
    clear(&app.details_cache)

    // Drop update flags for packages no longer installed
    to_drop := make([dynamic]string, 0, len(app.update_available))
    defer delete(to_drop)
    for p in app.update_available {
        if !app.installed_set[p] {
            append(&to_drop, p)
        }
    }
    for p in to_drop {
        delete_key(&app.update_available, p)
    }

    // Clean up old/stale cache entries for packages no longer available
    cleanup_persistent_cache(avail)
    log_cache_error("refresh_data: persistent cache cleanup returned successfully")

    // Recenter selection (new middle-locked scrolling)
    recenter_list(&app.left_selection, &app.left_scroll, len(app.available), 20)

    // Invalidate current details (will be refetched on draw if needed)
    app.needs_redraw = true
    return true
}

// After the package list is known: rehydrate fresh disk-cache hits into memory,
// then fetch at most DETAILS_FETCH_CHUNK missing/expired entries (from selection).
// Further gaps are filled on demand when the user focuses a package still missing.
preload_missing_details :: proc(app: ^App) {
    if len(app.available) == 0 {
        return
    }

    // Disk hits are cheap — load them all so cached packages scroll smoothly.
    for pkg in app.available {
        if _, ok := app.details_cache[pkg]; ok do continue
        if details, ok := load_details_from_cache(pkg); ok {
            app.details_cache[pkg] = details
            note_package_update_status(app, pkg, details)
        }
    }

    start := app.left_selection
    if start < 0 || start >= len(app.available) {
        start = 0
    }
    need := collect_details_to_fetch(app, start, DETAILS_FETCH_CHUNK)
    defer delete(need)
    fetch_details_chunk(app, need[:])
}

// Context-aware toggle:
//   not installed: toggle install mark
//   installed + update mark: clear update
//   installed + remove mark: clear remove
//   installed clean: mark remove (remove wins over update)
// Recent Operations list is rebuilt from pending maps after every change.
toggle_mark :: proc(app: ^App) {
    if len(app.available) == 0 do return
    if app.left_selection >= len(app.available) do return

    pkg := app.available[app.left_selection]

    if app.installed_set[pkg] {
        if app.pending_install[pkg] {
            // Clear update mark first
            delete_key(&app.pending_install, pkg)
        } else if app.pending_remove[pkg] {
            delete_key(&app.pending_remove, pkg)
        } else {
            app.pending_remove[pkg] = true
            delete_key(&app.pending_install, pkg)
        }
    } else {
        // Not installed: toggle install mark
        if app.pending_install[pkg] {
            delete_key(&app.pending_install, pkg)
        } else {
            app.pending_install[pkg] = true
            delete_key(&app.pending_remove, pkg)
        }
    }
    sync_pending_ops_list(app)
    app.needs_redraw = true
}

// Clear all pending install/remove/update marks and empty the staging list in RO.
// If we still know about updates from cache, re-show the passive hint.
clear_marks :: proc(app: ^App) {
    clear(&app.pending_install)
    clear(&app.pending_remove)
    clear_status_lines(app)
    app.updates_hint_shown = false
    if len(app.update_available) > 0 {
        maybe_show_updates_hint(app)
    }
    app.needs_redraw = true
}

// Drain non-blocking keys; true if Escape or Ctrl+C was pressed (cancel long op).
poll_cancel_key :: proc() -> bool {
    for {
        key := read_key()
        switch k in key {
        case Timeout:
            return false
        case Special_Key:
            if k == .Escape || k == .CtrlC {
                return true
            }
        case rune:
            // ignore
        case Unknown_Escape:
            // ignore
        }
    }
}

// `u`: refresh installed packages with missing/≥24h cache, then mark all known updates.
// Progress in RO; Esc cancels remaining fetches but keeps marks already applied.
mark_all_updates :: proc(app: ^App) {
    if len(app.installed) == 0 {
        clear_status_lines(app)
        append_status_line(app, "no updates to mark")
        app.needs_redraw = true
        return
    }

    // Ensure installed packages with warm cache are loaded into memory for compare.
    for pkg in app.installed {
        if _, ok := app.details_cache[pkg]; ok do continue
        if details, cached_at, ok := load_cached_details_meta(pkg); ok {
            now := time.to_unix_seconds(time.now())
            if now - cached_at < UPDATE_SCAN_MAX_AGE_SECONDS {
                app.details_cache[pkg] = details
                note_package_update_status(app, pkg, details)
            }
        }
    }

    // Packages that need a network re-fetch for the update scan
    to_scan := make([dynamic]string, 0, len(app.installed))
    defer delete(to_scan)
    for pkg in app.installed {
        if cache_stale_for_update_scan(pkg) {
            append(&to_scan, pkg)
        } else if det, ok := app.details_cache[pkg]; ok {
            note_package_update_status(app, pkg, det)
        } else if details, _, ok2 := load_cached_details_meta(pkg); ok2 {
            app.details_cache[pkg] = details
            note_package_update_status(app, pkg, details)
        }
    }

    cancelled := false
    if len(to_scan) > 0 {
        append_status_line(app, fmt.tprintf("scanning 0 of %d for updates", len(to_scan)))
        app.skip_details_ensure = true
        draw(app)
        app.skip_details_ensure = false

        done := 0
        for i := 0; i < len(to_scan); i += DETAILS_FETCH_CHUNK {
            if poll_cancel_key() {
                cancelled = true
                break
            }
            end := min(i + DETAILS_FETCH_CHUNK, len(to_scan))
            batch := to_scan[i:end]

            // Drop any in-memory entry so apply_fetched_details will store fresh results
            for pkg in batch {
                delete_key(&app.details_cache, pkg)
            }

            fetched := fetch_package_details_batch(batch)
            apply_fetched_details(app, batch, fetched[:])
            delete(fetched)

            done = end
            replace_last_status_line(app, fmt.tprintf("scanning %d of %d for updates", done, len(to_scan)))
            app.skip_details_ensure = true
            draw(app)
            app.skip_details_ensure = false
        }

        // Remove scanning progress line
        if len(app.status_lines) > 0 {
            last := app.status_lines[len(app.status_lines) - 1]
            if strings.has_prefix(last, "scanning ") {
                delete(last)
                pop(&app.status_lines)
            }
        }
    }

    // Mark all known updates (except pending remove)
    marked := 0
    for pkg in app.installed {
        if app.pending_remove[pkg] do continue
        has := app.update_available[pkg]
        if !has {
            if det, ok := app.details_cache[pkg]; ok && package_has_update(det) {
                app.update_available[pkg] = true
                has = true
            }
        }
        if has {
            app.pending_install[pkg] = true
            marked += 1
        }
    }

    app.updates_hint_shown = true // don't re-nudge after explicit u

    if marked == 0 {
        // Keep any prior non-staging lines minimal
        clear_status_lines(app)
        if cancelled {
            append_status_line(app, "update scan cancelled")
        }
        append_status_line(app, "no updates to mark")
    } else {
        sync_pending_ops_list(app)
        if cancelled {
            append_status_line(app, "update scan cancelled (partial marks kept)")
        }
    }
    app.needs_redraw = true
}

// Fetch package lists from deb-get (rate-limited).
fetch_list :: proc(app: ^App) {
    now := time.to_unix_seconds(time.now())
    if app.last_fetch_unix > 0 {
        elapsed := now - app.last_fetch_unix
        if elapsed < FETCH_COOLDOWN_SECONDS {
            wait := FETCH_COOLDOWN_SECONDS - elapsed
            // Keep pending mark lines; note cooldown at the end
            sync_pending_ops_list(app)
            append_status_line(app, fmt.tprintf("fetch cooldown: wait %ds", wait))
            app.needs_redraw = true
            return
        }
    }

    if refresh_data(app) {
        app.last_fetch_unix = time.to_unix_seconds(time.now())
        if len(app.pending_install) > 0 || len(app.pending_remove) > 0 {
            sync_pending_ops_list(app)
            append_status_line(app, "fetched package lists from deb-get")
        } else {
            clear_status_lines(app)
            append_status_line(app, "fetched package lists from deb-get")
        }
        // Warm details for cache misses (may show its own RO progress line).
        preload_missing_details(app)
    } else if app.last_error != "" {
        append_status_line(app, app.last_error)
    }
    app.needs_redraw = true
}

// Help text drawn in the package-details region when show_help is true.
// Uses the frame allocator (caller is draw()).
draw_help_pane :: proc(x, y, width, height: int) {
    lines := [?]string{
        "debtui — TUI front-end for deb-get",
        "",
        "Browse packages in the left list. Space toggles",
        "marks (press again to unmark). Installed:",
        "clear update → remove → clear. u scans installed",
        "packages for updates and marks them. Enter applies.",
        "Quit with pending marks asks to apply first.",
        "",
        "Keys:",
        "  ↑↓ / j k     Move selection",
        "  PgUp / PgDn  Page up / down",
        "  Home / End   First / last package",
        "  Space        Toggle mark",
        "  Enter        Apply all marks",
        "  u            Mark all updates (scan)",
        "  Esc          Cancel update scan (keep marks)",
        "  c            Clear all marks",
        "  f            Fetch list (rate limited)",
        "  ?            Toggle this help",
        "  q / Ctrl+C   Quit",
        "",
        "On apply, if sudo needs a password it is",
        "prompted in Recent Operations (masked).",
        "",
        "Markers:",
        "  [i] installed  [↑] update  [+] install",
        "  [-] remove",
        "",
        "Press ? again to return to package details.",
    }

    row := 0
    for line in lines {
        if row >= height do break

        // Soft-wrap long lines into the pane width
        if len(line) == 0 {
            row += 1
            continue
        }

        if len(line) <= width {
            move_cursor(x, y + row)
            set_bg(DETAIL_BG)
            if row == 0 {
                set_fg(Color.BrightCyan)
            } else if strings.has_prefix(line, "Keys:") || strings.has_prefix(line, "Markers:") {
                set_fg(COLOR_HEADER)
            } else {
                set_fg(DETAIL_FG)
            }
            write(line)
            pad := width - len(line)
            if pad > 0 {
                write(strings.repeat(" ", pad))
            }
            reset_attrs()
            row += 1
        } else {
            wrapped := wrap_text(line, width)
            for wl in wrapped {
                if row >= height do break
                move_cursor(x, y + row)
                set_bg(DETAIL_BG)
                set_fg(DETAIL_FG)
                write(wl)
                pad := width - len(wl)
                if pad > 0 {
                    write(strings.repeat(" ", pad))
                }
                reset_attrs()
                row += 1
            }
        }
    }
}

// Process all pending operations
apply_pending :: proc(app: ^App) {
    // Collect lists (copy because we clear as we go)
    to_install := make([dynamic]string, 0, len(app.pending_install))
    for p in app.pending_install {
        append(&to_install, p)
    }

    to_remove := make([dynamic]string, 0, len(app.pending_remove))
    for p in app.pending_remove {
        append(&to_remove, p)
    }

    if (len(to_install) == 0) && (len(to_remove) == 0) {
        clear_status_lines(app)
        append_status_line(app, "nothing to do")
        app.needs_redraw = true
        return
    }

    // Clear staging marks list; fill with apply progress
    clear_status_lines(app)
    app.needs_redraw = true
    draw(app)

    // Install/remove need root via deb-get's sudo. Prompt in Recent Operations
    // (stdout/stderr are redirected, so a normal TTY sudo prompt would not work).
    if !ensure_sudo_for_apply(app) {
        // Marks stay pending so the user can fix auth and press Enter again.
        // Rebuild mark lines, then re-append whatever sudo/password dialogue we showed.
        dialogue := make([dynamic]string, 0, len(app.status_lines))
        defer {
            for s in dialogue { delete(s) }
            delete(dialogue)
        }
        for line in app.status_lines {
            append(&dialogue, strings.clone(line))
        }
        sync_pending_ops_list(app)
        for line in dialogue {
            append_status_line(app, line)
        }
        append_status_line(app, "apply cancelled: elevation required")
        app.needs_redraw = true
        return
    }

    // Process one package at a time so we can report per-app status in the pane.
    // Installs first, then removes.

    for p in to_install {
        was_installed := app.installed_set[p]
        ok, _ := perform_install([]string{p})
        if ok {
            if was_installed {
                append_status_line(app, fmt.tprintf("updated: %s", p))
                delete_key(&app.update_available, p)
            } else {
                append_status_line(app, fmt.tprintf("installed: %s", p))
            }
        } else {
            if was_installed {
                append_status_line(app, fmt.tprintf("failed to update: %s", p))
            } else {
                append_status_line(app, fmt.tprintf("failed to install: %s", p))
            }
        }
        app.needs_redraw = true
        draw(app)  // live update in Recent Operations
    }

    for p in to_remove {
        ok, _ := perform_remove([]string{p})
        if ok {
            append_status_line(app, fmt.tprintf("removed: %s", p))
        } else {
            append_status_line(app, fmt.tprintf("failed to remove: %s", p))
        }
        app.needs_redraw = true
        draw(app)
    }

    // Final refresh so left list and installed markers update
    refresh_data(app)

    clear(&app.pending_install)
    clear(&app.pending_remove)

    app.needs_redraw = true
}

// --------------------------- Status pane helpers (Recent Operations) -----------

// Replace the last Recent Operations line (used for live password mask).
replace_last_status_line :: proc(app: ^App, line: string) {
    if len(app.status_lines) == 0 {
        append_status_line(app, line)
        return
    }
    last := len(app.status_lines) - 1
    delete(app.status_lines[last])
    app.status_lines[last] = strings.clone(line)
}

// Masked password entry in the Recent Operations panel.
// Returns a heap-allocated password string; caller must zero_and_delete_string.
read_password_in_ro :: proc(app: ^App) -> (password: string, ok: bool) {
    password_entry_active = true
    defer password_entry_active = false

    append_status_line(app, "password:")
    append_status_line(app, "")
    draw(app)

    buf: [512]byte
    n := 0

    for {
        key := read_key()

        switch k in key {
        case Special_Key:
            #partial switch k {
            case .Enter:
                pw := strings.clone(string(buf[:n]))
                for i in 0..<n {
                    buf[i] = 0
                }
                // Leave a non-secret confirmation line instead of the mask
                replace_last_status_line(app, "(password entered)")
                draw(app)
                return pw, true

            case .Backspace:
                if n > 0 {
                    n -= 1
                    buf[n] = 0
                }

            case .Escape, .CtrlC:
                for i in 0..<n {
                    buf[i] = 0
                }
                replace_last_status_line(app, "(cancelled)")
                draw(app)
                return "", false

            case:
                // ignore other specials
            }

        case rune:
            if k >= 32 && k < 127 && n < len(buf) {
                buf[n] = u8(k)
                n += 1
            }

        case Timeout:
            sleep_ms(16)
            continue

        case Unknown_Escape:
            // ignore
        }

        // Update mask row: only asterisks, never the real password
        if n == 0 {
            replace_last_status_line(app, "")
        } else {
            mask := strings.repeat("*", n)
            replace_last_status_line(app, mask)
        }
        draw(app)
    }
}

// Ensure sudo will not block deb-get install/remove. Prompts in RO if needed.
ensure_sudo_for_apply :: proc(app: ^App) -> bool {
    if running_as_root() {
        append_status_line(app, "sudo: running as root")
        draw(app)
        return true
    }

    if !sudo_available() {
        append_status_line(app, "sudo: not found (required for install/remove)")
        draw(app)
        return false
    }

    if sudo_credentials_cached() {
        append_status_line(app, "sudo: credentials already cached")
        draw(app)
        return true
    }

    append_status_line(app, "sudo: password required for package changes")
    draw(app)

    pw, ok := read_password_in_ro(app)
    if !ok {
        append_status_line(app, "sudo: password entry cancelled")
        draw(app)
        return false
    }
    defer zero_and_delete_string(pw)

    if !sudo_cache_credentials(pw) {
        append_status_line(app, "sudo: authentication failed")
        draw(app)
        return false
    }

    append_status_line(app, "sudo: authenticated")
    draw(app)
    return true
}

// Rebuild Recent Operations from current pending maps (sorted, clean on unmark).
// Order: updates (installed+install mark), new installs, removes.
sync_pending_ops_list :: proc(app: ^App) {
    clear_status_lines(app)

    if len(app.pending_install) > 0 {
        updates := make([dynamic]string, 0, len(app.pending_install))
        installs := make([dynamic]string, 0, len(app.pending_install))
        defer delete(updates)
        defer delete(installs)
        for p in app.pending_install {
            if app.installed_set[p] {
                append(&updates, p)
            } else {
                append(&installs, p)
            }
        }
        slice.sort(updates[:])
        slice.sort(installs[:])
        for p in updates {
            append_status_line(app, fmt.tprintf("marked for update: %s", p))
        }
        for p in installs {
            append_status_line(app, fmt.tprintf("marked for installation: %s", p))
        }
    }

    if len(app.pending_remove) > 0 {
        removes := make([dynamic]string, 0, len(app.pending_remove))
        defer delete(removes)
        for p in app.pending_remove {
            append(&removes, p)
        }
        slice.sort(removes[:])
        for p in removes {
            append_status_line(app, fmt.tprintf("marked for removal: %s", p))
        }
    }
}

append_status_line :: proc(app: ^App, line: string) {
    // Clone so callers may pass fmt.tprintf / other temporary strings.
    append(&app.status_lines, strings.clone(line))

    // Auto-scroll if we were at or near the bottom
    viewport := max(1, get_status_viewport_height())
    if len(app.status_lines) > viewport {
        if app.status_scroll >= len(app.status_lines) - viewport - 1 {
            app.status_scroll = len(app.status_lines) - viewport
        }
    } else {
        app.status_scroll = 0
    }
}

clear_status_lines :: proc(app: ^App) {
    for line in app.status_lines {
        delete(line)
    }
    clear(&app.status_lines)
    app.status_scroll = 0
}

// Visible log lines under the fixed mid-screen Recent Operations header.
get_status_viewport_height :: proc() -> int {
    h := term_height
    list_start_y := 3
    ro_y := recent_ops_header_y(h, list_start_y)
    // Rows from ro_y+1 through h-2 inclusive (above bottom status bar)
    return max(0, (h - 1) - (ro_y + 1))
}

// -----------------------------------------------------------------------------

// Ask the user whether to apply all pending changes before quitting (all-or-nothing).
// Message format: 'apply pending changes (y/N ##s)? '
// Default is No after a 10-second timeout.
confirm_and_maybe_apply_on_quit :: proc(app: ^App) -> bool {
    if len(app.pending_install) == 0 && len(app.pending_remove) == 0 {
        return true
    }

    h := term_height
    status_y := h - 1
    base_prompt := "apply pending changes (y/N "

    start := time.now()

    draw_prompt :: proc(status_y: int, base_prompt: string, secs: int) {
        move_cursor(1, status_y)
        set_bg(COLOR_STATUS_BG)
        set_fg(COLOR_STATUS_FG)

        for _ in 0..<term_width do write(" ")
        move_cursor(1, status_y)

        write(base_prompt)
        writef("%2ds)? ", secs)
        reset_attrs()
    }

    // Initial draw
    draw_prompt(status_y, base_prompt, 10)

    // 10 second timeout, checking ~10 times per second
    for {
        elapsed := time.duration_seconds(time.since(start))
        remaining := 10 - int(elapsed)
        if remaining < 0 do remaining = 0

        key := read_key()

        switch k in key {
        case rune:
            switch k {
            case 'y', 'Y':
                apply_pending(app)
                return true
            case 'n', 'N', '\r', '\n', 0x1b:
                return true
            }
        case Special_Key:
            if k == .Enter || k == .Escape {
                return true
            }
        case Timeout:
            // fall through to countdown update
        case Unknown_Escape:
            return true
        case:
            // ignore
        }

        // Redraw only when the displayed second changes (smooth countdown)
        current_secs := remaining
        if current_secs <= 0 {
            // timeout -> default No
            return true
        }

        // Update the countdown display
        draw_prompt(status_y, base_prompt, current_secs)

        // Small sleep so we don't spin too hard (read_key already has 0.1s VTIME)
        sleep_ms(50)
    }

    return true
}

// Handle a key press. Returns true if we should continue the main loop.
handle_key :: proc(app: ^App, key: Key) -> bool {
    switch k in key {
    case Special_Key:
        #partial switch k {
        case .Up, .Down:
            delta := 1 if k == .Down else -1
            // Use the actual available height of the list panel (matches draw())
            vp := term_height - 4
            move_selection(&app.left_selection, &app.left_scroll, len(app.available), delta, vp)
            app.needs_redraw = true

        case .Enter:
            apply_pending(app)

        case .PageUp, .PageDown:
            dir := 1 if k == .PageDown else -1
            vp := term_height - 4
            page_move(&app.left_selection, &app.left_scroll, len(app.available), dir, vp)
            app.needs_redraw = true

        case .Home, .End:
            to_end := k == .End
            vp := term_height - 4
            jump_to(&app.left_selection, &app.left_scroll, len(app.available), to_end, vp)
            app.needs_redraw = true

        case .Escape:
            // Ignore lone ESC (common when user presses ESC or partial sequences arrive)
            // Only Ctrl-C and 'q' should quit for now.

        case .CtrlC:
            if confirm_and_maybe_apply_on_quit(app) {
                app.running = false
            }

        case .CtrlR:
            // Same as f — rate-limited list fetch
            fetch_list(app)

        case:
            // ignore other specials for now
        }

    case rune:
        switch k {
        case 'q', 'Q':
            // Terminal restore is handled solely by shutdown_terminal / atexit.
            if confirm_and_maybe_apply_on_quit(app) {
                app.running = false
            }

        case ' ':
            toggle_mark(app)

        case 'c', 'C':
            clear_marks(app)

        case 'f', 'F':
            fetch_list(app)

        case 'u', 'U':
            mark_all_updates(app)

        case 'j', 'J':
            vp := term_height - 4
            move_selection(&app.left_selection, &app.left_scroll, len(app.available), +1, vp)
            app.needs_redraw = true

        case 'k', 'K':
            vp := term_height - 4
            move_selection(&app.left_selection, &app.left_scroll, len(app.available), -1, vp)
            app.needs_redraw = true

        case '?':
            app.show_help = !app.show_help
            app.needs_redraw = true

        case:
            // unknown char - ignore
        }

    case Unknown_Escape:
        // ignore unknown escapes
    case Timeout:
        // should not reach here from handle_key
        return true
    }

    return app.running
}

// Print a short session summary on the primary screen after terminal restore.
// Plain text only — no ANSI colors (uses the user's default terminal colors).
print_exit_summary :: proc(app: ^App) {
    fmt.printf("debtui %s — session summary\n", DEBTUI_VERSION)
    fmt.printf("  packages available:  %d\n", len(app.available))
    fmt.printf("  packages installed:  %d\n", len(app.installed))

    n_pending := len(app.pending_install) + len(app.pending_remove)
    if n_pending > 0 {
        fmt.printf("  pending (not applied): %d install/update, %d remove\n",
            len(app.pending_install), len(app.pending_remove))
    }

    if len(app.status_lines) > 0 {
        fmt.println("  recent operations:")
        // Cap so a long session does not flood the shell
        max_lines := 20
        start := 0
        if len(app.status_lines) > max_lines {
            start = len(app.status_lines) - max_lines
            fmt.printf("    … %d earlier lines omitted\n", start)
        }
        for i in start..<len(app.status_lines) {
            fmt.printf("    %s\n", app.status_lines[i])
        }
    } else {
        fmt.println("  recent operations:    (none this session)")
    }

    if app.last_error != "" {
        fmt.printf("  last error: %s\n", app.last_error)
    }

    fmt.println("Goodbye.")
}

// --------------------------- Main --------------------------------------------

main :: proc() {
    // Handle --version and --verbose/-v early, before touching the terminal
    for arg in os.args[1:] {
        if arg == "--version" {
            fmt.printf("debtui %s\n", DEBTUI_VERSION)
            os.exit(0)
        }
        if arg == "--verbose" || arg == "-v" {
            verbose = true
        }
    }

    if !init_terminal() {
        fmt.eprintln("Failed to initialize terminal. Are you running in a proper terminal?")
        os.exit(1)
    }
    defer shutdown_terminal()

    install_resize_handler()

    app := init_app()
    defer destroy_app(&app)

    // Initial data load (counts as a fetch for cooldown purposes)
    if refresh_data(&app) {
        app.last_fetch_unix = time.to_unix_seconds(time.now())
        // Fill in-memory + disk cache for any missing/expired package details.
        // Shows "loading details: n/m" in Recent Operations when many are needed.
        preload_missing_details(&app)
    }
    // Still continue on failure — user will see error in status
    if verbose {
        log_cache_error(fmt.tprintf("main: refresh_data completed, available=%d packages, initial_selection=%d", len(app.available), app.left_selection))
        if len(app.available) > 0 {
            first_pkg := app.available[app.left_selection]
            log_cache_error(fmt.tprintf("main: first package to draw details for will be '%s'", first_pkg))
        }

        log_cache_error("main: about to perform initial draw()")
    }
    // Initial draw
    draw(&app)
    if verbose {
        log_cache_error("main: initial draw() returned")
    }

    // Simple main loop. We redraw only when needed.
    // For better responsiveness we could also redraw on timer for clock etc., but not necessary.
    for app.running {
        // Handle terminal resize if SIGWINCH fired
        if handle_pending_resize() {
            app.needs_redraw = true
        }

        // Non-blocking friendly read with small sleep when idle
        key := read_key()

        // Timeout means no key was available this tick (our VTIME in raw mode)
        if _, is_timeout := key.(Timeout); is_timeout {
            if app.needs_redraw {
                draw(&app)
                app.needs_redraw = false
            }
            sleep_ms(16)   // ~60 fps cap when active
            continue
        }

        // Real key arrived
        still_running := handle_key(&app, key)

        if app.needs_redraw {
            draw(&app)
            app.needs_redraw = false
        }

        if !still_running {
            break
        }

        sleep_ms(5)
    }

    // Leave alt-screen, clear primary buffer, restore cooked mode, then
    // print a plain-text summary with the user's default terminal colors.
    // (defer shutdown_terminal is then a no-op via terminal_restored.)
    shutdown_terminal()
    print_exit_summary(&app)
}
