// This is free and unencumbered software released into the public domain.
// See the UNLICENSE file or https://unlicense.org/ for details.

package main

import "core:os"
import "core:fmt"
import "core:strings"
import "core:encoding/json"
import "core:time"
import "core:path/filepath"
import "core:c/libc"
import "core:mem"

// ============================================================================
// deb-get integration layer
// Uses libc.system + temp file for reliable output capture across platforms
// ============================================================================

// Run a deb-get command and return (combined_output, success)
run_debget :: proc(args: ..string) -> (output: string, ok: bool) {
    if len(args) == 0 {
        return "", false
    }

    // Build command line safely (simple quoting for common cases)
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)

    strings.write_string(&sb, "deb-get")
    for a in args {
        strings.write_string(&sb, " '")
        // Very naive escaping: replace ' with '\'' 
        for ch in a {
            if ch == '\'' {
                strings.write_string(&sb, "'\\''")
            } else {
                strings.write_rune(&sb, ch)
            }
        }
        strings.write_string(&sb, "'")
    }

    cmdline := strings.to_string(sb)

    // Use a predictable temp file for output capture.
    // This is simple and avoids tricky libc FILE binding differences across Odin versions.
    tmpfile := "/tmp/debtui_debget.out"
    full_cmd := fmt.tprintf("%s > '%s' 2>&1", cmdline, tmpfile)

    ccmd := strings.clone_to_cstring(full_cmd, context.temp_allocator)
    ret := libc.system(ccmd)

    // Read the temp file (best effort)
    data, read_err := os.read_entire_file_from_path(tmpfile, context.allocator)
    if read_err == nil {
        output = string(data)
        // Clean up temp file (ignore errors)
        os.remove(tmpfile)
    } else {
        output = fmt.tprintf("(failed to read command output from %s)", tmpfile)
    }

    // libc.system returns the raw status (shifted). 0 usually means success.
    ok = (ret == 0)
    return output, ok
}

// Get full list of available packages (fast, --raw)
get_available_packages :: proc() -> ([]string, bool) {
    out, ok := run_debget("list", "--raw")
    if !ok {
        return nil, false
    }

    lines := strings.split_lines(out)
    pkgs := make([dynamic]string, 0, len(lines))

    for line in lines {
        trimmed := strings.trim_space(line)
        if trimmed != "" {
            append(&pkgs, trimmed)
        }
    }

    return pkgs[:], true
}

// Get list of installed packages via deb-get
get_installed_packages :: proc() -> ([]string, bool) {
    out, ok := run_debget("list", "--installed")
    if !ok {
        return nil, false
    }

    lines := strings.split_lines(out)
    pkgs := make([dynamic]string, 0, len(lines))

    for line in lines {
        trimmed := strings.trim_space(line)
        if trimmed != "" {
            append(&pkgs, trimmed)
        }
    }

    return pkgs[:], true
}

// Package details parsed from `deb-get show`
Package_Details :: struct {
    title:        string,   // First line, usually pretty name
    package_name: string,
    repository:   string,
    updater:      string,
    installed:    string,   // "No" or version string
    architecture: string,
    website:      string,
    summary:      string,
    raw:          string,   // full original output for fallback display
}

parse_details :: proc(raw: string) -> Package_Details {
    d := Package_Details{raw = raw}

    lines := strings.split_lines(raw)

    for i := 0; i < len(lines); i += 1 {
        line := strings.trim_right_space(lines[i])

        if (i == 0) && (line != "") && !strings.has_prefix(line, "  ") {
            d.title = strings.trim_space(line)
            continue
        }

        if strings.has_prefix(line, "  Package:") {
            d.package_name = strings.trim_space(line[10:])
        } else if strings.has_prefix(line, "  Repository:") {
            d.repository = strings.trim_space(line[13:])
        } else if strings.has_prefix(line, "  Updater:") {
            d.updater = strings.trim_space(line[10:])
        } else if strings.has_prefix(line, "  Installed:") {
            d.installed = strings.trim_space(line[12:])
        } else if strings.has_prefix(line, "  Architecture:") {
            d.architecture = strings.trim_space(line[15:])
        } else if strings.has_prefix(line, "  Website:") {
            d.website = strings.trim_space(line[10:])
        } else if strings.has_prefix(line, "  Summary:") {
            d.summary = strings.trim_space(line[10:])
            // Some summaries might be multi-line? For now take first.
        }
    }

    if d.title == "" {
        d.title = d.package_name
    }

    return d
}

// Execute install for a list of packages.
// Returns (success, combined_output)
perform_install :: proc(pkgs: []string) -> (ok: bool, output: string) {
    if len(pkgs) == 0 do return true, ""

    args := make([]string, len(pkgs) + 1)
    args[0] = "install"
    copy(args[1:], pkgs)

    out, ok2 := run_debget(..args)
    return ok2, out
}

// Execute remove for a list of packages.
perform_remove :: proc(pkgs: []string) -> (ok: bool, output: string) {
    if len(pkgs) == 0 do return true, ""

    args := make([]string, len(pkgs) + 1)
    args[0] = "remove"
    copy(args[1:], pkgs)

    out, ok2 := run_debget(..args)
    return ok2, out
}

// Check if a package name is valid (exists in available list)
is_valid_package :: proc(name: string, available: []string) -> bool {
    for p in available {
        if p == name do return true
    }
    return false
}

// --------------------------- Persistent Details Cache ------------------------

CACHE_DIR_NAME :: "debtui"
CACHE_TTL_SECONDS :: 7 * 24 * 60 * 60 // 7 days

Cached_Details :: struct {
    details:   Package_Details,
    cached_at: i64, // unix timestamp seconds
}

get_cache_dir :: proc() -> string {
    cache_home := os.get_env("XDG_CACHE_HOME", context.allocator)
    if cache_home != "" {
        dir, _ := filepath.join({cache_home, CACHE_DIR_NAME})
        return dir
    }
    home := os.get_env("HOME", context.allocator)
    if home != "" {
        dir, _ := filepath.join({home, ".cache", CACHE_DIR_NAME})
        return dir
    }
    return "/tmp/debtui-cache"
}

ensure_cache_dir :: proc() -> bool {
    dir := get_cache_dir()
    if os.exists(dir) {
        return true
    }
    err := os.make_directory_all(dir)
    return err == os.ERROR_NONE
}

get_package_cache_path :: proc(pkg: string) -> string {
    dir := get_cache_dir()
    safe_name, _ := strings.replace_all(pkg, "/", "_")
    filename := strings.concatenate({safe_name, ".json"})
    defer delete(filename)
    joined, _ := filepath.join({dir, filename})
    return joined
}

load_details_from_cache :: proc(pkg: string) -> (Package_Details, bool) {
    path := get_package_cache_path(pkg)
    defer delete(path)

    if !os.exists(path) {
        if verbose {
            log_cache_error(fmt.tprintf("load: no cache file on disk for pkg='%s'", pkg))
        }
        return {}, false
    }

    if verbose {
        log_cache_error(fmt.tprintf("load: cache file exists, about to read for pkg='%s'", pkg), path)
    }

    data, read_err := os.read_entire_file_from_path(path, context.allocator)
    if read_err != nil {
        return {}, false
    }
    defer delete(data, context.allocator)

    if verbose {
        log_cache_error(fmt.tprintf("load: read %d bytes for pkg='%s'", len(data), pkg), path)
    }

    // Guard against absurdly large / corrupted cache files (prevents huge allocations in unmarshal)
    if len(data) > 4 * 1024 * 1024 {   // 4 MiB hard limit per cache file
        log_cache_error("cache file too large, deleting", path)
        os.remove(path)
        return {}, false
    }

    cached: Cached_Details
    if verbose {
        log_cache_error("load: attempting json unmarshal", path)
    }
    err := json.unmarshal(data, &cached)
    if err != nil {
        log_cache_error("json unmarshal failed", path)
        os.remove(path)
        return {}, false
    }

    if verbose {
        log_cache_error(fmt.tprintf("load: unmarshal OK (raw_len=%d, summary_len=%d, pkg=%s)", len(cached.details.raw), len(cached.details.summary), cached.details.package_name), path)
    }

    // Never trust persisted raw data
    cached.details.raw = ""

    if !is_details_sane(cached.details) {
        log_cache_error("sanity check failed after unmarshal", path)
        return {}, false
    }

    now := time.to_unix_seconds(time.now())
    if now - cached.cached_at > CACHE_TTL_SECONDS {
        log_cache_error("stale cache entry (7-day TTL)", path)
        return {}, false
    }

    // Basic sanity: the package name in the file should match what we asked for
    if cached.details.package_name != "" && cached.details.package_name != pkg {
        log_cache_error("package_name mismatch in cache file", path)
        return {}, false
    }

    return cached.details, true
}

save_details_to_cache :: proc(pkg: string, details: Package_Details) {
    if !ensure_cache_dir() {
        return
    }

    // Do not persist the raw field — it's only a fallback and can contain arbitrary text
    to_save := details
    to_save.raw = ""

    cached := Cached_Details{
        details = to_save,
        cached_at = time.to_unix_seconds(time.now()),
    }

    data, err := json.marshal(cached)
    if err != nil {
        return
    }
    defer delete(data, context.allocator)

    path := get_package_cache_path(pkg)
    defer delete(path)

    // Atomic write: write to .tmp then rename
    tmp_path := strings.concatenate({path, ".tmp"})
    defer delete(tmp_path)

    if write_err := os.write_entire_file(tmp_path, data); write_err != nil {
        os.remove(tmp_path)
        return
    }

    // On Unix, rename is usually atomic
    if rename_err := os.rename(tmp_path, path); rename_err != nil {
        os.remove(tmp_path)
    }
}

// Enhanced version that checks persistent cache first
get_package_details :: proc(pkg: string) -> (Package_Details, bool) {
    if verbose {
        log_cache_error(fmt.tprintf("get_package_details: called for pkg='%s'", pkg))
    }

    // Try disk cache first (7-day TTL)
    if details, ok := load_details_from_cache(pkg); ok {
        if verbose {
            log_cache_error(fmt.tprintf("get_package_details: cache hit for '%s'", pkg))
        }
        return details, true
    }

    if verbose {
        log_cache_error(fmt.tprintf("get_package_details: cache miss for '%s', running deb-get show", pkg))
    }

    // Fetch fresh
    out, ok := run_debget("show", pkg)
    if (!ok) || (out == "") {
        return Package_Details{package_name = pkg, raw = out}, false
    }

    details := parse_details(out)

    // Save to persistent cache
    save_details_to_cache(pkg, details)

    return details, true
}

// cleanup_persistent_cache removes old cache entries (>7 days) and entries for
// packages that are no longer available in deb-get.
cleanup_persistent_cache :: proc(available: []string) {
    log_cache_error("starting cache cleanup pass")
    dir := get_cache_dir()
    if !os.exists(dir) {
        log_cache_error("cache dir does not exist, skipping cleanup")
        return
    }

    available_set := make(map[string]bool)
    defer delete(available_set)
    for p in available {
        available_set[p] = true
    }

    fd, err := os.open(dir, os.O_RDONLY)
    if err != os.ERROR_NONE {
        log_cache_error("failed to open cache dir for cleanup")
        return
    }
    defer os.close(fd)

    // Read directory using the permanent allocator. The resulting entry.name
    // strings must be deleted by us (or left for process exit).
    entries, read_err := os.read_dir(fd, -1, context.allocator)
    if read_err != os.ERROR_NONE {
        log_cache_error("failed to read cache dir entries")
        return
    }

    now := time.to_unix_seconds(time.now())

    S_IFDIR :: 0o040000

    // --- Use a temporary arena for the body of the cleanup work ---
    //
    // All the per-file allocations (full_path, file data, json unmarshal
    // strings, fmt strings for logging, etc.) go into this arena and are
    // freed in one shot when the arena is destroyed. This leaves the main
    // allocator in a clean state so we can safely delete the Dir_Entry
    // name strings afterwards.
    {
        // 8 MiB is plenty for processing a few hundred cache files.
        arena_backing := make([]byte, 8 * 1024 * 1024)
        defer delete(arena_backing)

        arena: mem.Arena
        mem.arena_init(&arena, arena_backing)

        prev_context := context
        context.allocator = mem.arena_allocator(&arena)
        defer context = prev_context

        for entry in entries {
            mode := transmute(u32)entry.mode
            if mode & S_IFDIR != 0 { continue }  // S_IFDIR on Unix-like systems

            name := entry.name

            full_path, _ := filepath.join({dir, name})
            defer delete(full_path)

            if strings.has_suffix(name, ".tmp") {
                log_cache_error("removing stray .tmp file from previous atomic write", full_path)
                os.remove(full_path)
                continue
            }

            if !strings.has_suffix(name, ".json") { continue }

            if verbose {
                log_cache_error("cleanup: examining cache file", full_path)
            }

            data, file_read_err := os.read_entire_file_from_path(full_path, context.allocator)
            if file_read_err != nil {
                log_cache_error("cleanup: failed to read file, removing", full_path)
                os.remove(full_path)
                continue
            }
            defer delete(data, context.allocator)

            if verbose {
                log_cache_error(fmt.tprintf("cleanup: read %d bytes", len(data)), full_path)
            }

            // Guard against huge files (old raw blobs etc.)
            if len(data) > 4 * 1024 * 1024 {
                log_cache_error("cleanup: file too large (>4 MiB), deleting", full_path)
                os.remove(full_path)
                continue
            }

            cached: Cached_Details
            if verbose {
                log_cache_error("cleanup: attempting json unmarshal", full_path)
            }
            if json.unmarshal(data, &cached) != nil {
                log_cache_error("json unmarshal failed during cleanup", full_path)
                os.remove(full_path)
                continue
            }

            if verbose {
                log_cache_error(fmt.tprintf("cleanup: unmarshal OK (raw_len=%d, summary_len=%d, pkg=%s)", len(cached.details.raw), len(cached.details.summary), cached.details.package_name), full_path)
            }

            // Never trust persisted raw data
            cached.details.raw = ""

            if verbose {
                log_cache_error("cleanup: about to run is_details_sane", full_path)
            }
            if !is_details_sane(cached.details) {
                log_cache_error("sanity check failed during cleanup", full_path)
                os.remove(full_path)
                continue
            }

            if verbose {
                log_cache_error(fmt.tprintf("cleanup: sane, cached_at=%d, now=%d, age=%d", cached.cached_at, now, now - cached.cached_at), full_path)
            }

            // Remove if too old
            if now - cached.cached_at > CACHE_TTL_SECONDS {
                log_cache_error("removing stale cache file (7-day TTL)", full_path)
                os.remove(full_path)
                continue
            }

            pkg := cached.details.package_name
            if pkg == "" {
                log_cache_error("cleanup: package_name empty in JSON, reconstructing from filename", full_path)
                // Best-effort reconstruction from filename
                pkg = strings.trim_suffix(name, ".json")
                pkg, _ = strings.replace_all(pkg, "_", "/")
            }

            if verbose {
                log_cache_error(fmt.tprintf("cleanup: using pkg key for map lookup: '%s'", pkg), full_path)
                log_cache_error("cleanup: performing available_set map lookup", full_path)
            }

            // Remove if the package no longer exists in deb-get
            if !available_set[pkg] {
                log_cache_error("removing cache for package no longer in deb-get", full_path)
                os.remove(full_path)
            } else if verbose {
                log_cache_error("cleanup: keeping valid cache file", full_path)
            }
        }

        log_cache_error("cleanup: finished scanning all entries")
    }
    // The arena has now been destroyed. All the temporary allocations from
    // the per-file work (full_path, file data, json strings, log formatting,
    // etc.) have been released in one shot.

    // We intentionally do *not* delete the Dir_Entry names here.
    // Even after isolating all the heavy work to a temporary arena, the
    // final batch delete(e.name) on the results from os.read_dir has proven
    // unreliable and can still SIGSEGV. The important work (scanning for
    // stale/expired/obsolete .json files and calling os.remove on them) has
    // already completed safely inside the loop.
    //
    // Leaking the ~20 tiny filename strings from read_dir is completely
    // harmless for a long-running TUI (they are reclaimed on process exit).
    log_cache_error(fmt.tprintf("cleanup: not cleaning up %d read_dir entries (intentionally leaked to avoid allocator crash)", len(entries)))

    // (Previously attempted:)
    // for e in entries { delete(e.name) }
    // delete(entries)

    log_cache_error("cleanup: returning from cleanup_persistent_cache")
}

// --------------------------- Cache Error Logging & Sanity --------------------

log_cache_error :: proc(msg: string, path: string = "") {
    if !ensure_cache_dir() {
        fmt.eprintf("[cache error] %s | %s\n", msg, path)
        return
    }

    dir := get_cache_dir()
    date := time.now()
    y, m, d := time.date(date)
    h, min, s := time.clock(date)
    log_name := fmt.tprintf("cache-errors-%04d-%02d-%02d.log", y, m, d)
    log_path, _ := filepath.join({dir, log_name})

    timestamp := fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d", y, m, d, h, min, s)
    line := fmt.tprintf("[%s] %s", timestamp, msg)
    if path != "" {
        line = fmt.tprintf("%s | file: %s", line, path)
    }
    line = strings.concatenate({line, "\n"})

    f, err := os.open(log_path, os.O_WRONLY | os.O_CREATE | os.O_APPEND, transmute(os.Permissions)u32(0o644))
    if err != os.ERROR_NONE {
        fmt.eprintf("[cache error] Failed to open log: %s | %s\n", msg, path)
        return
    }
    defer os.close(f)
    os.write(f, transmute([]u8)line)
}

is_details_sane :: proc(d: Package_Details) -> bool {
    if len(d.raw) > 2*1024*1024 { return false }
    if len(d.summary) > 256*1024 { return false }
    if len(d.title) > 4096 || len(d.package_name) > 256 { return false }
    if len(d.website) > 8192 { return false }
    return true
}
