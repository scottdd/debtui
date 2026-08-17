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
import "core:sys/posix"

// ============================================================================
// deb-get integration layer
// Uses libc.system + temp file for reliable output capture across platforms
// ============================================================================

// Create a private, exclusive temp file path for deb-get output capture.
// Avoids a fixed world-writable path under /tmp (race / hijack risk).
// Mode is forced to 0600 after create.
make_debget_temp_path :: proc() -> (path: string, ok: bool) {
    f, err := os.create_temp_file("", "debtui-*.out")
    if err != nil {
        return "", false
    }
    // Clone the path before close; the file stays on disk for the shell redirect.
    path = strings.clone(os.name(f))
    os.close(f)
    _ = os.change_mode(path, os.perm_number(0o600))
    return path, true
}

// Own a copy of detail strings (empty stays empty; no free needed for "").
clone_field :: proc(s: string, allocator := context.allocator) -> string {
    if s == "" do return ""
    return strings.clone(s, allocator)
}

// Deep-copy Package_Details so fields are independent of deb-get output buffers.
// Does not copy `raw` (not persisted; avoids huge blobs in the details cache).
clone_details :: proc(d: Package_Details, allocator := context.allocator) -> Package_Details {
    return Package_Details{
        title        = clone_field(d.title, allocator),
        package_name = clone_field(d.package_name, allocator),
        repository   = clone_field(d.repository, allocator),
        updater      = clone_field(d.updater, allocator),
        installed    = clone_field(d.installed, allocator),
        published    = clone_field(d.published, allocator),
        architecture = clone_field(d.architecture, allocator),
        website      = clone_field(d.website, allocator),
        summary      = clone_field(d.summary, allocator),
        raw          = "",
    }
}

// Free heap strings in a Package_Details (no-op on empty fields).
free_details :: proc(d: Package_Details) {
    if d.title != "" do delete(d.title)
    if d.package_name != "" do delete(d.package_name)
    if d.repository != "" do delete(d.repository)
    if d.updater != "" do delete(d.updater)
    if d.installed != "" do delete(d.installed)
    if d.published != "" do delete(d.published)
    if d.architecture != "" do delete(d.architecture)
    if d.website != "" do delete(d.website)
    if d.summary != "" do delete(d.summary)
    if d.raw != "" do delete(d.raw)
}

// Shell-escape a path for single-quoted use in a system() command line.
shell_quote :: proc(s: string, allocator := context.allocator) -> string {
    sb: strings.Builder
    strings.builder_init(&sb, allocator)
    strings.write_byte(&sb, '\'')
    for ch in s {
        if ch == '\'' {
            strings.write_string(&sb, "'\\''")
        } else {
            strings.write_rune(&sb, ch)
        }
    }
    strings.write_byte(&sb, '\'')
    return strings.to_string(sb)
}

// True if we are root (no elevation needed).
running_as_root :: proc() -> bool {
    return posix.geteuid() == 0
}

// True if sudo is available on PATH.
sudo_available :: proc() -> bool {
    return libc.system(cstring("command -v sudo >/dev/null 2>&1")) == 0
}

// True if sudo will not ask for a password right now (cached credentials or NOPASSWD).
sudo_credentials_cached :: proc() -> bool {
    return libc.system(cstring("sudo -n true >/dev/null 2>&1")) == 0
}

// Overwrite heap string bytes then free (for password wipe).
zero_and_delete_string :: proc(s: string) {
    if len(s) == 0 {
        return
    }
    p := raw_data(s)
    for i in 0..<len(s) {
        p[i] = 0
    }
    delete(s)
}

// Cache sudo credentials using password on stdin (-S). Does not put the password
// on the process command line (writes a 0600 temp file, redirects into sudo).
sudo_cache_credentials :: proc(password: string) -> bool {
    path, ok := make_debget_temp_path()
    if !ok {
        return false
    }
    defer {
        os.remove(path)
        delete(path)
    }

    // Restrict to owner only (create_temp_file may use broader perms).
    _ = os.change_mode(path, os.perm_number(0o600))

    data := make([]byte, len(password) + 1)
    defer {
        for i in 0..<len(data) {
            data[i] = 0
        }
        delete(data)
    }
    if len(password) > 0 {
        copy(data, transmute([]u8)password)
    }
    data[len(password)] = '\n'

    if os.write_entire_file(path, data) != nil {
        return false
    }

    cmd := fmt.tprintf("sudo -S -v < %s 2>/dev/null", shell_quote(path, context.temp_allocator))
    ccmd := strings.clone_to_cstring(cmd, context.temp_allocator)
    return libc.system(ccmd) == 0
}

// Run a deb-get command and return (combined_output, success).
// Caller owns `output` and must `delete(output)` when non-empty.
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
        strings.write_string(&sb, " ")
        strings.write_string(&sb, shell_quote(a, context.temp_allocator))
    }

    cmdline := strings.to_string(sb)

    tmpfile, tmp_ok := make_debget_temp_path()
    if !tmp_ok {
        return strings.clone("(failed to create private temp file for deb-get output)"), false
    }
    defer {
        os.remove(tmpfile)
        delete(tmpfile)
    }

    full_cmd := fmt.tprintf("%s > %s 2>&1", cmdline, shell_quote(tmpfile, context.temp_allocator))

    ccmd := strings.clone_to_cstring(full_cmd, context.temp_allocator)
    ret := libc.system(ccmd)

    // Read the temp file (best effort); ownership of `data` transfers to caller as `output`
    data, read_err := os.read_entire_file_from_path(tmpfile, context.allocator)
    if read_err == nil {
        output = string(data)
    } else {
        output = strings.clone(fmt.tprintf("(failed to read command output from %s)", tmpfile))
    }

    // libc.system returns the raw status (shifted). 0 usually means success.
    ok = (ret == 0)
    return output, ok
}

// Debian-style package name: starts with alnum, then alnum / + . - _
// Rejects deb-get status lines, ANSI warnings, and paths.
is_package_name :: proc(s: string) -> bool {
    if len(s) == 0 || len(s) > 128 {
        return false
    }
    c0 := s[0]
    if !((c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z') || (c0 >= '0' && c0 <= '9')) {
        return false
    }
    for i in 0..<len(s) {
        c := s[i]
        switch c {
        case 'a'..='z', 'A'..='Z', '0'..='9', '-', '+', '.', '_':
            continue
        case:
            return false
        }
    }
    return true
}

// Parse package name lines from deb-get list output into owned strings.
// Skips warnings, ANSI, and other non-name lines. Frees `out`.
parse_package_list_output :: proc(out: string) -> []string {
    if out == "" {
        return nil
    }
    defer delete(out)

    lines := strings.split_lines(out)
    defer delete(lines)

    pkgs := make([dynamic]string, 0, len(lines))
    for line in lines {
        trimmed := strings.trim_space(line)
        if is_package_name(trimmed) {
            append(&pkgs, strings.clone(trimmed))
        }
    }
    return pkgs[:]
}

// Full local catalog (manifest + 99-local + builtins). Caller owns the slice
// and each name.
//
// Always --include-unsupported: that dumps APPS without validate_deb (~40ms)
// and without intersecting /var/cache/deb-get/supported_apps.list.
// `list --raw` without that file walks every package (~10s) and prints
// "WARNING! Cached file ..." on stdout. With a stale file it hides names
// that are already in the manifest but not yet in the supported index.
//
// This is the on-disk catalog only. New upstream packages appear after
// `deb-get update` rewrites /etc/deb-get/*.repo; then the next startup or f.
get_available_packages :: proc() -> ([]string, bool) {
    out, ok := run_debget("list", "--include-unsupported", "--raw")
    if !ok {
        if out != "" do delete(out)
        return nil, false
    }
    return parse_package_list_output(out), true
}

// Installed names from deb-get's installed file. Caller owns the slice and each name.
get_installed_packages :: proc() -> ([]string, bool) {
    out, ok := run_debget("list", "--include-unsupported", "--installed")
    if !ok {
        if out != "" do delete(out)
        return nil, false
    }
    return parse_package_list_output(out), true
}

// Package details parsed from `deb-get show`
Package_Details :: struct {
    title:        string,   // First line, usually pretty name
    package_name: string,
    repository:   string,
    updater:      string,
    installed:    string,   // "No" or version string
    published:    string,   // available version (deb-get updater); often empty for apt
    architecture: string,
    website:      string,
    summary:      string,
    raw:          string,   // full original output for fallback display
}

// Max age of a details cache file before `u` will re-fetch it (installed only).
// Everyday browse still uses CACHE_TTL_SECONDS (7 days).
UPDATE_SCAN_MAX_AGE_SECONDS :: 24 * 60 * 60

// Apply a single "  Key: value" line to details. Returns true if recognized.
apply_details_field :: proc(d: ^Package_Details, line: string) -> bool {
    if strings.has_prefix(line, "  Package:") {
        // Prefer the first Package: line (some entries print secondary repo lines later)
        if d.package_name == "" {
            d.package_name = strings.trim_space(line[len("  Package:"):])
        }
        return true
    }
    if strings.has_prefix(line, "  Repository:") {
        if d.repository == "" {
            d.repository = strings.trim_space(line[len("  Repository:"):])
        }
        return true
    }
    if strings.has_prefix(line, "  Updater:") {
        d.updater = strings.trim_space(line[len("  Updater:"):])
        return true
    }
    if strings.has_prefix(line, "  Installed:") {
        d.installed = strings.trim_space(line[len("  Installed:"):])
        return true
    }
    if strings.has_prefix(line, "  Published:") {
        d.published = strings.trim_space(line[len("  Published:"):])
        return true
    }
    if strings.has_prefix(line, "  Architecture:") {
        d.architecture = strings.trim_space(line[len("  Architecture:"):])
        return true
    }
    if strings.has_prefix(line, "  Website:") {
        d.website = strings.trim_space(line[len("  Website:"):])
        return true
    }
    if strings.has_prefix(line, "  Summary:") {
        d.summary = strings.trim_space(line[len("  Summary:"):])
        return true
    }
    return false
}

parse_details :: proc(raw: string) -> Package_Details {
    d := Package_Details{raw = raw}

    lines := strings.split_lines(raw)
    defer delete(lines)

    for i := 0; i < len(lines); i += 1 {
        line := strings.trim_right_space(lines[i])

        if (i == 0) && (line != "") && !strings.has_prefix(line, "  ") {
            d.title = strings.trim_space(line)
            continue
        }

        _ = apply_details_field(&d, line)
    }

    if d.title == "" {
        d.title = d.package_name
    }

    return d
}

// Parse `deb-get show pkg1 pkg2 ...` multi-package output into one entry per package.
// Field strings are slices into `raw` (caller must keep `raw` alive or clone fields).
parse_details_list :: proc(raw: string) -> [dynamic]Package_Details {
    results := make([dynamic]Package_Details)
    current: Package_Details
    has_block := false

    lines := strings.split_lines(raw)
    defer delete(lines)
    for line in lines {
        trimmed := strings.trim_right_space(line)
        if trimmed == "" do continue

        // Package title lines are unindented; status/warning lines from deb-get are indented.
        if !strings.has_prefix(trimmed, " ") && !strings.has_prefix(trimmed, "\t") {
            if has_block && current.package_name != "" {
                if current.title == "" {
                    current.title = current.package_name
                }
                append(&results, current)
            }
            current = Package_Details{title = strings.trim_space(trimmed)}
            has_block = true
            continue
        }

        if apply_details_field(&current, trimmed) {
            has_block = true
        }
    }

    if has_block && current.package_name != "" {
        if current.title == "" {
            current.title = current.package_name
        }
        append(&results, current)
    }

    return results
}

// Run `deb-get show` for one or more packages, parse, write disk cache, return parsed list.
// Each returned Package_Details owns its string fields (caller free_details each).
// On total failure returns empty list.
fetch_package_details_batch :: proc(pkgs: []string) -> [dynamic]Package_Details {
    results := make([dynamic]Package_Details)
    if len(pkgs) == 0 {
        return results
    }

    args := make([]string, len(pkgs) + 1)
    defer delete(args)
    args[0] = "show"
    for i in 0..<len(pkgs) {
        args[i + 1] = pkgs[i]
    }

    out, ok := run_debget(..args)
    if out == "" {
        return results
    }
    defer delete(out)
    _ = ok

    if len(pkgs) == 1 {
        details := parse_details(out)
        owned := clone_details(details)
        if owned.package_name == "" {
            owned.package_name = strings.clone(pkgs[0])
        }
        if is_details_sane(owned) {
            save_details_to_cache(owned.package_name, owned)
            append(&results, owned)
        } else {
            free_details(owned)
        }
        return results
    }

    list := parse_details_list(out)
    defer delete(list)

    by_name := make(map[string]bool)
    defer delete(by_name)
    for d in list {
        if d.package_name == "" || !is_details_sane(d) do continue
        owned := clone_details(d)
        save_details_to_cache(owned.package_name, owned)
        by_name[owned.package_name] = true
        append(&results, owned)
    }

    // Fall back to single-package show for any names missing from multi parse.
    for pkg in pkgs {
        if by_name[pkg] do continue
        if details, ok2 := get_package_details(pkg); ok2 {
            append(&results, details)
        }
    }

    return results
}

// Execute install for a list of packages.
// Returns (success, combined_output). Caller must delete(output) when non-empty.
perform_install :: proc(pkgs: []string) -> (ok: bool, output: string) {
    if len(pkgs) == 0 do return true, ""

    args := make([]string, len(pkgs) + 1)
    defer delete(args)
    args[0] = "install"
    copy(args[1:], pkgs)

    out, ok2 := run_debget(..args)
    return ok2, out
}

// Execute remove for a list of packages.
// Returns (success, combined_output). Caller must delete(output) when non-empty.
perform_remove :: proc(pkgs: []string) -> (ok: bool, output: string) {
    if len(pkgs) == 0 do return true, ""

    args := make([]string, len(pkgs) + 1)
    defer delete(args)
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
        free_details(cached.details)
        return {}, false
    }

    now := time.to_unix_seconds(time.now())
    if now - cached.cached_at > CACHE_TTL_SECONDS {
        log_cache_error("stale cache entry (7-day TTL)", path)
        free_details(cached.details)
        return {}, false
    }

    // Basic sanity: the package name in the file should match what we asked for
    if cached.details.package_name != "" && cached.details.package_name != pkg {
        log_cache_error("package_name mismatch in cache file", path)
        free_details(cached.details)
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
        if out != "" do delete(out)
        return Package_Details{package_name = strings.clone(pkg)}, false
    }

    details := parse_details(out)
    owned := clone_details(details)
    delete(out)

    if owned.package_name == "" {
        owned.package_name = strings.clone(pkg)
    }

    // Save to persistent cache
    save_details_to_cache(pkg, owned)

    return owned, true
}

// cleanup_persistent_cache removes old cache entries (>7 days) and entries for
// packages that are no longer available in deb-get.
//
// Uses os.read_all_directory_by_path + file_info_slice_delete so directory
// entries are freed with the API that allocated them (avoids the prior
// manual delete(e.name) SIGSEGV).
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

    entries, read_err := os.read_all_directory_by_path(dir, context.allocator)
    if read_err != nil {
        log_cache_error("failed to read cache dir entries")
        return
    }
    defer os.file_info_slice_delete(entries, context.allocator)

    now := time.to_unix_seconds(time.now())

    // Per-file scratch (JSON, paths for logs) lives in a scratch arena so the
    // permanent allocator only holds the File_Info slice we free above.
    arena_backing := make([]byte, 8 * 1024 * 1024)
    defer delete(arena_backing)

    arena: mem.Arena
    mem.arena_init(&arena, arena_backing)
    scratch := mem.arena_allocator(&arena)

    for entry in entries {
        if entry.type == .Directory {
            continue
        }

        name := entry.name
        full_path := entry.fullpath

        if strings.has_suffix(name, ".tmp") {
            log_cache_error("removing stray .tmp file from previous atomic write", full_path)
            os.remove(full_path)
            continue
        }

        if !strings.has_suffix(name, ".json") {
            continue
        }

        if verbose {
            log_cache_error("cleanup: examining cache file", full_path)
        }

        free_all(scratch)
        prev_alloc := context.allocator
        context.allocator = scratch

        data, file_read_err := os.read_entire_file_from_path(full_path, scratch)
        if file_read_err != nil {
            context.allocator = prev_alloc
            log_cache_error("cleanup: failed to read file, removing", full_path)
            os.remove(full_path)
            continue
        }

        if verbose {
            log_cache_error(fmt.tprintf("cleanup: read %d bytes", len(data)), full_path)
        }

        if len(data) > 4 * 1024 * 1024 {
            context.allocator = prev_alloc
            log_cache_error("cleanup: file too large (>4 MiB), deleting", full_path)
            os.remove(full_path)
            continue
        }

        cached: Cached_Details
        if json.unmarshal(data, &cached, allocator=scratch) != nil {
            context.allocator = prev_alloc
            log_cache_error("json unmarshal failed during cleanup", full_path)
            os.remove(full_path)
            continue
        }

        cached.details.raw = ""

        if !is_details_sane(cached.details) {
            context.allocator = prev_alloc
            log_cache_error("sanity check failed during cleanup", full_path)
            os.remove(full_path)
            continue
        }

        if now - cached.cached_at > CACHE_TTL_SECONDS {
            context.allocator = prev_alloc
            log_cache_error("removing stale cache file (7-day TTL)", full_path)
            os.remove(full_path)
            continue
        }

        pkg := cached.details.package_name
        if pkg == "" {
            // Best-effort reconstruction from filename (arena-backed)
            pkg = strings.trim_suffix(name, ".json")
            pkg, _ = strings.replace_all(pkg, "_", "/", allocator = scratch)
        }

        // Map lookup uses permanent available_set; keys are package names
        // from the outer list (not arena memory).
        keep := available_set[pkg]
        context.allocator = prev_alloc

        if !keep {
            log_cache_error("removing cache for package no longer in deb-get", full_path)
            os.remove(full_path)
        } else if verbose {
            log_cache_error("cleanup: keeping valid cache file", full_path)
        }
    }

    log_cache_error(fmt.tprintf("cleanup: finished scanning %d entries", len(entries)))
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
    if len(d.published) > 256 { return false }
    return true
}

// True if `newer` is strictly greater than `older` per dpkg version rules.
// Empty either side → false (unknown, not an update).
version_is_newer :: proc(newer, older: string) -> bool {
    if newer == "" || older == "" do return false
    // dpkg --compare-versions A gt B  → exit 0 if A > B
    cmd := fmt.tprintf(
        "dpkg --compare-versions %s gt %s",
        shell_quote(newer, context.temp_allocator),
        shell_quote(older, context.temp_allocator),
    )
    ccmd := strings.clone_to_cstring(cmd, context.temp_allocator)
    return libc.system(ccmd) == 0
}

// True when details indicate a deb-get-managed package has a newer Published version.
// Empty Published or non-comparable versions → not an update (unknown).
package_has_update :: proc(d: Package_Details) -> bool {
    inst := strings.trim_space(d.installed)
    pub := strings.trim_space(d.published)
    if inst == "" || inst == "No" do return false
    if pub == "" do return false
    // Apt-backed packages usually have no Published line; if present, still compare.
    // Prefer deb-get updater when known.
    up := strings.trim_space(d.updater)
    if up != "" && up != "deb-get" do return false
    return version_is_newer(pub, inst)
}

// Read cache file metadata without the 7-day soft miss used by load_details_from_cache.
// ok=false if missing, unreadable, corrupt, or past the hard 7-day TTL.
load_cached_details_meta :: proc(pkg: string) -> (details: Package_Details, cached_at: i64, ok: bool) {
    path := get_package_cache_path(pkg)
    defer delete(path)

    if !os.exists(path) {
        return {}, 0, false
    }

    data, read_err := os.read_entire_file_from_path(path, context.allocator)
    if read_err != nil {
        return {}, 0, false
    }
    defer delete(data, context.allocator)

    if len(data) > 4 * 1024 * 1024 {
        return {}, 0, false
    }

    cached: Cached_Details
    if json.unmarshal(data, &cached) != nil {
        return {}, 0, false
    }
    cached.details.raw = ""
    if !is_details_sane(cached.details) {
        free_details(cached.details)
        return {}, 0, false
    }
    if cached.details.package_name != "" && cached.details.package_name != pkg {
        free_details(cached.details)
        return {}, 0, false
    }

    now := time.to_unix_seconds(time.now())
    if now - cached.cached_at > CACHE_TTL_SECONDS {
        free_details(cached.details)
        return {}, 0, false
    }
    return cached.details, cached.cached_at, true
}

// True if `u` should re-run deb-get show for this package (missing or ≥ 24h old).
cache_stale_for_update_scan :: proc(pkg: string) -> bool {
    _, cached_at, ok := load_cached_details_meta(pkg)
    if !ok do return true
    now := time.to_unix_seconds(time.now())
    return now - cached_at >= UPDATE_SCAN_MAX_AGE_SECONDS
}
