// This is free and unencumbered software released into the public domain.
// See the UNLICENSE file or https://unlicense.org/ for details.

package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

DEBTUI_VERSION :: "0.1.0"

// Global verbose flag controlled by --verbose / -v.
// When false, we suppress the detailed diagnostic logging that was added
// during the SIGSEGV investigation (load:, get_package_details:, draw:,
// detailed cleanup per-file lines, etc.). Real errors and important
// operational messages are still always logged.
verbose := false

// ============================================================================
// debtui - TUI frontend for deb-get
//
// Layout (two panes):
//   +---------------------------+--------------------------------+
//   | LEFT: Available packages  | RIGHT: Package details         |
//   | (scrollable list)         | (for currently selected item)  |
//   |                           |                                |
//   |                           | Recent Operations              |
//   |                           | (list install/uninstall status |
//   |                           | info from most recent APPLY)   |
//   +---------------------------+--------------------------------+
//   | Status bar: pending marks + throbber during operations     |
//   +------------------------------------------------------------+
//
// All marking and navigation happens in the single left list.
// `i` = mark for install, `u` = mark for uninstall (on installed items).
// Details always reflect the left list selection.
// ============================================================================

// --------------------------- App State ---------------------------------------

App :: struct {
    // Data from deb-get
    available: []string,
    installed: []string,

    // Which packages are already installed (for quick lookup + markers in left list)
    installed_set: map[string]bool,

    // Pending actions
    pending_install: map[string]bool,
    pending_remove:  map[string]bool,

    // Left list (the only list) state
    left_selection:  int,
    left_scroll:     int,

    // Details cache (package name -> details string or struct)
    details_cache: map[string]Package_Details,

    // Current rendered details for left selection
    current_details: Package_Details,

    // UI / terminal
    needs_redraw: bool,
    running:      bool,
    last_error:   string,      // shown in status for a while
    last_message: string,      // success messages etc.

    // For processing feedback (throbber removed; using status pane instead)
    // processing:   bool,
    // spinner_frame: int,
    // process_output: string,

    // Recent Operations status pane (bottom 75% of right column)
    status_lines:  [dynamic]string,
    status_scroll: int,
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

// ASCII spinner frames for processing feedback
spinner_frames := [?]string{"|", "/", "-", "\\"}

// Draw a single list item with optional markers.
// Always writes exactly `width` characters so the pane looks solid.
draw_list_item :: proc(x, y, width: int, text: string, is_selected: bool, is_installed: bool, is_pending_install: bool, is_pending_remove: bool) {
    move_cursor(x, y)

    bg := BASE_BG
    text_fg := COLOR_NORMAL
    tag_fg := COLOR_NORMAL
    prefix := "  "

    if is_pending_install {
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
        // so [i] / [+] / [-] remain clearly visible against the cyan highlight.
        if prefix != "  " {
            tag_fg = COLOR_SELECTED
        }
    }

    set_bg(bg)

    tag_display := "   "   // normal (no marker) alignment: three spaces
    tag_len := 3
    if prefix != "  " {
        tag_display = strings.concatenate({" ", prefix, " "})
        tag_len = len(tag_display)
    }

    // Write the tag/marker portion in tag_fg (bright on focused row)
    set_fg(tag_fg)
    write(tag_display)

    // Write package name (possibly truncated) + padding in text color
    set_fg(text_fg)
    name := text
    if tag_len + len(name) > width {
        max_name := width - tag_len - 1
        if max_name < 1 {
            max_name = 1
        }
        name = strings.concatenate({name[:max_name], "…"})
    }

    write(name)

    // Pad the rest of the line with the background color
    written := tag_len + len(name)
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

    // Establish base colors for the TUI (black background, white text)
    set_bg(BASE_BG)
    set_fg(BASE_FG)

    // Make sure we start from a clean attribute state for this frame
    reset_attrs()
    set_bg(BASE_BG)
    set_fg(BASE_FG)

    // Layout calculations - simplified two-pane layout
    left_width  := w * 45 / 100
    right_width := w - left_width - 1   // 1 for separator

    left_x  := 1
    right_x := left_width + 2

    header_y := 1
    list_start_y := 3

    // Details pane now takes the full remaining height on the right
    details_start_y := list_start_y

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

    // ---------------- Details header (now full height on right) ----------------
    move_cursor(right_x, list_start_y - 1)
    write(strings.repeat(" ", right_width))
    move_cursor(right_x, list_start_y - 1)
    set_fg(COLOR_HEADER)
    write("Package details")
    reset_attrs()

    // ---------------- Draw vertical separator (full height) ----------------
    draw_vline(left_width + 1, list_start_y - 1, h - 3, '│')

    // ---------------- Draw lists ----------------

    // LEFT: Available (now uses nearly full height)
    left_viewport := h - 5   // leave room for header + status bar
    recenter_list(&app.left_selection, &app.left_scroll, len(app.available), left_viewport)

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

        draw_list_item(left_x, y, left_width, pkg, is_sel, is_inst, is_pend, is_pend_rm)
    }

    // ---------------- RIGHT: Split into Package details (top ~25%) + Recent Operations (bottom ~75%) ----------------
    right_content_top := details_start_y
    right_content_h := h - 1 - right_content_top   // above the global bottom status bar
    if right_content_h < 6 do right_content_h = 6

    details_portion_h := max(4, right_content_h * 25 / 100)
    status_portion_h := right_content_h - details_portion_h

    detail_y := right_content_top
    detail_h := details_portion_h

    // Blank the details portion
    for i in 0..<detail_h {
        move_cursor(right_x, detail_y + i)
        set_bg(DETAIL_BG)
        set_fg(DETAIL_FG)
        spaces := strings.repeat(" ", right_width)
        write(spaces)
        reset_attrs()
    }

    // Show details for current left selection (top portion)
    if (len(app.available) > 0) && (app.left_selection < len(app.available)) {
        sel_pkg := app.available[app.left_selection]

        if verbose {
            log_cache_error(fmt.tprintf("draw: about to ensure details for current selection '%s'", sel_pkg))
        }

        // Ensure we have details
        if _, ok := app.details_cache[sel_pkg]; !ok {
            if details, ok2 := get_package_details(sel_pkg); ok2 {
                app.details_cache[sel_pkg] = details
            } else {
                app.details_cache[sel_pkg] = Package_Details{
                    package_name = sel_pkg,
                    raw = "Failed to fetch details from deb-get",
                }
            }
        }

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
            {"Installed",   det.installed},
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
    } else {
        move_cursor(right_x, detail_y)
        set_fg(COLOR_DIM)
        write("(no package selected)")
        reset_attrs()
    }

    // ---------------- Recent Operations (bottom ~75% of right column) ----------------
    status_region_y := detail_y + detail_h
    if status_portion_h > 0 {
        // Blank the status portion (including space for its header)
        for i in 0..<status_portion_h {
            move_cursor(right_x, status_region_y + i)
            set_bg(DETAIL_BG)   // reuse dark bg for consistency
            set_fg(DETAIL_FG)
            spaces := strings.repeat(" ", right_width)
            write(spaces)
            reset_attrs()
        }

        // Header for the status pane
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

        // Draw the status lines with auto-scroll viewport
        status_view_h := status_portion_h - 1   // leave room for header
        if status_view_h < 1 do status_view_h = 1

        // Make sure scroll is reasonable
        max_scroll := max(0, len(app.status_lines) - status_view_h)
        if app.status_scroll > max_scroll do app.status_scroll = max_scroll
        if app.status_scroll < 0 do app.status_scroll = 0

        for i in 0..<status_view_h {
            idx := app.status_scroll + i
            y := status_region_y + 1 + i
            if y >= h - 1 do break
            if idx >= len(app.status_lines) {
                // blank remaining
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

            // Color logic:
            // success (installed/removed) -> green action + white pkg
            // failure -> red action + white pkg
            // package name always the normal white used in left list
            is_success := strings.has_prefix(line, "installed:") || strings.has_prefix(line, "removed:")
            action_color := Color.BrightGreen
            if !is_success {
                action_color = Color.BrightRed
            }

            // Find split point for coloring
            colon_idx := strings.index(line, ": ")
            if colon_idx >= 0 {
                action_part := line[:colon_idx+2]
                pkg_part := line[colon_idx+2:]

                // Truncate if needed to fit width
                total_needed := len(action_part) + len(pkg_part)
                if total_needed > right_width {
                    max_pkg := right_width - len(action_part) - 1
                    if max_pkg < 1 { max_pkg = 1 }
                    pkg_part = strings.concatenate({pkg_part[:max_pkg], "…"})
                }

                set_fg(action_color)
                write(action_part)
                set_fg(COLOR_NORMAL)   // same white as left list names
                write(pkg_part)

                // pad
                written := len(action_part) + len(pkg_part)
                if written < right_width {
                    write(strings.repeat(" ", right_width - written))
                }
            } else {
                // fallback
                set_fg(COLOR_NORMAL)
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

    // ---------------- Status bar ----------------
    status_y := h - 1
    move_cursor(1, status_y)
    set_bg(COLOR_STATUS_BG)
    set_fg(COLOR_STATUS_FG)

    // Clear the line first
    for _ in 0..<w do write(" ")
    move_cursor(1, status_y)

    // Pending summary
    n_install := len(app.pending_install)
    n_remove  := len(app.pending_remove)

    if (n_install > 0) || (n_remove > 0) {
        set_fg(Color.BrightYellow)
        if n_install > 0 {
            writef("%d to install", n_install)
        }
        if (n_install > 0) && (n_remove > 0) {
            write("  ")
        }
        if n_remove > 0 {
            writef("%d to remove", n_remove)
        }
        set_fg(COLOR_STATUS_FG)
        write("   •   ")
    }

    // Key hints (context sensitive a bit)
    write("↑↓/jk: move  i: mark install  u: mark uninstall  Enter: apply  r: reset  R: refresh  q: quit")

    if app.last_error != "" {
        set_fg(Color.BrightRed)
        write("   ERROR: ")
        write(app.last_error)
        set_fg(COLOR_STATUS_FG)
    } else if app.last_message != "" {
        set_fg(Color.BrightGreen)
        write("   ")
        write(app.last_message)
        set_fg(COLOR_STATUS_FG)
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
        status_lines      = make([dynamic]string),
    }
    return app
}

destroy_app :: proc(app: ^App) {
    delete(app.details_cache)
    delete(app.installed_set)
    delete(app.pending_install)
    delete(app.pending_remove)
    delete(app.status_lines)
    if app.available != nil do delete(app.available)
    if app.installed != nil do delete(app.installed)
}

// Load (or reload) data from deb-get
refresh_data :: proc(app: ^App) -> bool {
    app.last_error = ""
    app.last_message = ""

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

    // Clean up old/stale cache entries for packages no longer available
    cleanup_persistent_cache(avail)
    log_cache_error("refresh_data: persistent cache cleanup returned successfully")

    // Recenter selection (new middle-locked scrolling)
    recenter_list(&app.left_selection, &app.left_scroll, len(app.available), 20)

    // Invalidate current details (will be refetched on draw if needed)
    app.needs_redraw = true
    return true
}

// Mark current left selection for install (if not already installed)
toggle_mark_install :: proc(app: ^App) {
    if len(app.available) == 0 do return
    if app.left_selection >= len(app.available) do return

    pkg := app.available[app.left_selection]

    // Don't allow marking already installed packages for install
    if app.installed_set[pkg] {
        app.last_message = fmt.tprintf("%s is already installed", pkg)
        return
    }

    if app.pending_install[pkg] {
        delete_key(&app.pending_install, pkg)
        app.last_message = fmt.tprintf("Unmarked %s", pkg)
    } else {
        app.pending_install[pkg] = true
        // If it was somehow in remove (shouldn't happen), clear it
        delete_key(&app.pending_remove, pkg)
        app.last_message = fmt.tprintf("Marked %s for installation", pkg)
    }
    app.needs_redraw = true
}

// Mark current left selection for removal (only if it is installed)
toggle_mark_remove :: proc(app: ^App) {
    if len(app.available) == 0 do return
    if app.left_selection >= len(app.available) do return

    pkg := app.available[app.left_selection]

    if !app.installed_set[pkg] {
        app.last_message = fmt.tprintf("%s is not installed", pkg)
        return
    }

    if app.pending_remove[pkg] {
        delete_key(&app.pending_remove, pkg)
        app.last_message = fmt.tprintf("Unmarked %s", pkg)
    } else {
        app.pending_remove[pkg] = true
        // Remove from install queue if present (edge case)
        delete_key(&app.pending_install, pkg)
        app.last_message = fmt.tprintf("Marked %s for removal", pkg)
    }
    app.needs_redraw = true
}

// Clear all marks
reset_marks :: proc(app: ^App) {
    n := len(app.pending_install) + len(app.pending_remove)
    clear(&app.pending_install)
    clear(&app.pending_remove)
    if n > 0 {
        app.last_message = "All marks cleared"
    } else {
        app.last_message = ""
    }
    app.needs_redraw = true
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
        app.last_message = "Nothing to do"
        app.needs_redraw = true
        return
    }

    // Clear previous operation results and start fresh (per user spec)
    clear_status_lines(app)

    // Process one package at a time so we can report per-app status in the pane.
    // Installs first, then removes.

    for p in to_install {
        ok, _ := perform_install([]string{p})
        if ok {
            append_status_line(app, fmt.tprintf("installed: %s", p))
        } else {
            append_status_line(app, fmt.tprintf("failed to install: %s", p))
        }
        app.needs_redraw = true
        draw(app)  // live update in status pane
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

append_status_line :: proc(app: ^App, line: string) {
    append(&app.status_lines, line)

    // Auto-scroll if we were at or near the bottom
    viewport := max(1, get_status_viewport_height())
    if len(app.status_lines) > viewport {
        // if previously at bottom, keep at bottom
        if app.status_scroll >= len(app.status_lines) - viewport - 1 {
            app.status_scroll = len(app.status_lines) - viewport
        }
    } else {
        app.status_scroll = 0
    }
}

clear_status_lines :: proc(app: ^App) {
    clear(&app.status_lines)
    app.status_scroll = 0
}

get_status_viewport_height :: proc() -> int {
    h := term_height
    right_content_h := h - 1 - 3   // rough, above global status bar, below header area
    if right_content_h < 4 do right_content_h = 4
    details_portion := max(4, right_content_h * 25 / 100)
    return right_content_h - details_portion - 1  // -1 for the "Recent Operations" header
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
    app.last_error = ""
    app.last_message = ""

    switch k in key {
    case Special_Key:
        #partial switch k {
        case .Up, .Down:
            delta := 1 if k == .Down else -1
            // Use the actual available height of the list panel (matches draw())
            vp := term_height - 5
            move_selection(&app.left_selection, &app.left_scroll, len(app.available), delta, vp)
            app.needs_redraw = true

        case .Enter:
            clear_status_lines(app)
            apply_pending(app)

        case .PageUp, .PageDown:
            dir := 1 if k == .PageDown else -1
            vp := term_height - 5
            page_move(&app.left_selection, &app.left_scroll, len(app.available), dir, vp)
            app.needs_redraw = true

        case .Home, .End:
            to_end := k == .End
            vp := term_height - 5
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
            refresh_data(app)

        case:
            // ignore other specials for now
        }

    case rune:
        switch k {
        case 'q', 'Q':
            if confirm_and_maybe_apply_on_quit(app) {
			        // Clear screen
			        set_fg(Color.White)
			        set_bg(BgColor.Black)
			        reset_attrs()		// none of these does nothing. There's got to be a way to restore default terminal colors and send 'clear'/'cls'
			        fmt.print("\x1b[2J\x1b[H")
              app.running = false
            }

        case 'i', 'I':
            toggle_mark_install(app)

        case 'u', 'U':
            toggle_mark_remove(app)

        case 'r':
            reset_marks(app)

        case 'R':
            refresh_data(app)
            clear_status_lines(app)
            app.last_message = "Refreshed from deb-get"

        case 'j', 'J':
            vp := term_height - 5
            move_selection(&app.left_selection, &app.left_scroll, len(app.available), +1, vp)
            app.needs_redraw = true

        case 'k', 'K':
            vp := term_height - 5
            move_selection(&app.left_selection, &app.left_scroll, len(app.available), -1, vp)
            app.needs_redraw = true

        // h/l no longer switch panes (single list mode)

        case '/':
            // Future: filtering
            app.last_message = "Search/filter not implemented yet"

        case '?':
            app.last_message = "i: mark install  u: mark uninstall  Enter: apply  r: reset  R: refresh  q: quit"

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

// After apply_pending we show the command output in a simple "press any key" screen
// (kept for now but no longer triggered; output now lives in the Recent Operations pane)
show_process_result :: proc(app: ^App) {
    // The new status pane in the right column replaces this full-screen result view.
    app.last_message = ""
    app.last_error = ""
    app.needs_redraw = true
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

    // Initial data load
    if !refresh_data(&app) {
        // Still continue — user will see error in status
    }
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

    // Clean exit message (optional)
    fmt.println("\r\ndebtui exited cleanly.")
}
