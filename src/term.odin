// This is free and unencumbered software released into the public domain.
// See the UNLICENSE file or https://unlicense.org/ for details.

package main

import "core:os"
import "core:fmt"
import "base:runtime"
import "core:sys/posix"
import "core:c"
import "core:c/libc"
import "core:time"

foreign import libc_sys "system:c"

foreign libc_sys {
    ioctl :: proc(fd: c.int, request: c.ulong, argp: rawptr) -> c.int ---
}

// ============================================================================
// Terminal control - raw mode, alternate screen, ANSI helpers
// Zero-dependency TUI primitives for debtui
// ============================================================================

// Original terminal state for restoration
termios_original: posix.termios
terminal_restored := false

// Terminal size (updated on SIGWINCH or startup)
term_width  := 80
term_height := 24

// ANSI helpers
CSI :: "\x1b["
ALT_SCREEN_ON   :: "?1049h"
ALT_SCREEN_OFF  :: "?1049l"
CURSOR_HIDE     :: "?25l"
CURSOR_SHOW     :: "?25h"
CLEAR_SCREEN    :: "2J"
CLEAR_LINE      :: "2K"
HOME            :: "H"

// Colors (using 256-color where possible for niceness, fallback safe)
Color :: enum u8 {
    Reset      = 0,
    Black      = 30,
    Red        = 31,
    Green      = 32,
    Yellow     = 33,
    Blue       = 34,
    Magenta    = 35,
    Cyan       = 36,
    White      = 37,
    BrightBlack   = 90,
    BrightRed     = 91,
    BrightGreen   = 92,
    BrightYellow  = 93,
    BrightBlue    = 94,
    BrightMagenta = 95,
    BrightCyan    = 96,
    BrightWhite   = 97,
}

BgColor :: enum u8 {
    Reset      = 0,
    Black      = 40,
    Red        = 41,
    Green      = 42,
    Yellow     = 43,
    Blue       = 44,
    Magenta    = 45,
    Cyan       = 46,
    White      = 47,
    BrightBlack   = 100,
    BrightRed     = 101,
    BrightGreen   = 102,
    BrightYellow  = 103,
    BrightBlue    = 104,
    BrightMagenta = 105,
    BrightCyan    = 106,
    BrightWhite   = 107,
}

// Key representation returned by read_key
Timeout        :: struct {}
Unknown_Escape :: struct {}

Key :: union {
    rune,           // regular character
    Special_Key,
    Unknown_Escape, // raw escape sequence we didn't recognize
    Timeout,        // no key available (from VTIME)
}

Special_Key :: enum {
    Up,
    Down,
    Left,
    Right,
    Enter,
    Escape,
    Backspace,
    Tab,
    Home,
    End,
    PageUp,
    PageDown,
    Delete,
    CtrlC,
    CtrlD,
    CtrlR,
    CtrlL,
    // Add more as needed
}

// Restore terminal state (registered via atexit for safety)
restore_terminal :: proc "c" () {
    if terminal_restored do return
    context = runtime.default_context()

    posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &termios_original)
    // Best effort restores
    os.write_string(os.stderr, CSI)
    os.write_string(os.stderr, ALT_SCREEN_OFF)
    os.write_string(os.stderr, CSI)
    os.write_string(os.stderr, CURSOR_SHOW)
    os.write_string(os.stderr, "\r\n")
    terminal_restored = true
}

// Enable raw mode + alternate screen + hide cursor
init_terminal :: proc() -> bool {
    if posix.tcgetattr(posix.STDIN_FILENO, &termios_original) != .OK {
        fmt.eprintln("Failed to get terminal attributes")
        return false
    }

    libc.atexit(restore_terminal)

    raw := termios_original

    // Input flags
    raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
    // Output flags
    raw.c_oflag -= {.OPOST}
    // Control flags
    raw.c_cflag |= {.CS8}
    // Local flags: disable echo, canonical, signals (we handle Ctrl-C ourselves), extended
    raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}

    // Non-blocking read with 0.1s timeout (good for escape seq timeout too)
    // V.MIN and V.TIME indices for Linux (common across glibc)
    raw.c_cc[cast(posix.Control_Char)6] = 0   // V.MIN
    raw.c_cc[cast(posix.Control_Char)5] = 1   // V.TIME  (tenths of a second)

    if posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw) != .OK {
        fmt.eprintln("Failed to set raw terminal mode")
        return false
    }

    // Enter alternate screen + full clear with black background.
    // This is the most reliable way to avoid painting over previous shell content.
    fmt.print(CSI, ALT_SCREEN_ON)
    fmt.print("\x1b[40;37m")   // black bg, white fg
    fmt.print(CSI, CLEAR_SCREEN)
    fmt.print(CSI, HOME)
    fmt.print(CSI, CURSOR_HIDE)

    update_terminal_size()
    return true
}

shutdown_terminal :: proc() {
    restore_terminal()
}

// Minimal winsize struct for ioctl (Linux)
WINSIZE :: struct {
    ws_row:    u16,
    ws_col:    u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
}

// TIOCGWINSZ on Linux amd64 (most common value)
TIOCGWINSZ :: 0x5413

// Get current terminal size using ioctl
update_terminal_size :: proc() {
    ws: WINSIZE
    if ioctl(c.int(posix.STDIN_FILENO), c.ulong(TIOCGWINSZ), &ws) == 0 {
        if ws.ws_col > 0 do term_width  = int(ws.ws_col)
        if ws.ws_row > 0 do term_height = int(ws.ws_row)
    }
}

// Move cursor to 1-based position (x=col, y=row)
move_cursor :: proc(x, y: int) {
    fmt.printf("%s%d;%dH", CSI, y, x)
}

// Set foreground color
set_fg :: proc(c: Color) {
    fmt.printf("%s%dm", CSI, u8(c))
}

// Set background color
set_bg :: proc(c: BgColor) {
    fmt.printf("%s%dm", CSI, u8(c))
}

reset_attrs :: proc() {
    fmt.print(CSI, "0m")
}

// Clear from cursor to end of line
clear_to_eol :: proc() {
    fmt.print(CSI, "K")
}

// Clear entire screen
clear_screen :: proc() {
    fmt.print(CSI, "2J")
    fmt.print(CSI, "H")
}

// Write a string at current cursor (caller manages position)
write :: proc(s: string) {
    os.write_string(os.stdout, s)
}

// Write a formatted string (convenience)
writef :: proc(fmt_str: string, args: ..any) {
    fmt.printf(fmt_str, ..args)
}

// Draw a horizontal line using box chars (or fallback)
draw_hline :: proc(x, y, width: int, ch: rune = '─') {
    move_cursor(x, y)
    for _ in 0..<width {
        fmt.printf("%c", ch)
    }
}

// Draw a vertical line
draw_vline :: proc(x, y, height: int, ch: rune = '│') {
    for i in 0..<height {
        move_cursor(x, y + i)
        fmt.printf("%c", ch)
    }
}

// Read a single key with proper escape sequence handling.
// This is the heart of keyboard input for the TUI.
read_key :: proc() -> Key {
    buf: [16]byte
    n, err := os.read(os.stdin, buf[:])
    if (err != nil) || (n <= 0) {
        return Timeout{} // idle / no key this tick
    }

    b := buf[0]

    // Ctrl keys
    if b == 3  do return Special_Key.CtrlC
    if b == 4  do return Special_Key.CtrlD
    if b == 18 do return Special_Key.CtrlR
    if b == 12 do return Special_Key.CtrlL

    // Enter / Return (handle early because \r is < 32)
    if (b == '\r') || (b == '\n') do return Special_Key.Enter

    // Normal printable
    if (b >= 32) && (b < 127) {
        if b == '\t' do return Special_Key.Tab
        return rune(b)
    }

    // Backspace
    if (b == 127) || (b == 8) {
        return Special_Key.Backspace
    }

    // Escape or escape sequence
    if b == 0x1b {
        // Collect the full escape sequence.
        // The initial read may have already delivered several bytes (common for arrows).
        sequence: [8]byte
        seq_len := n   // n = how many bytes we got in the first read

        // Copy what we already received
        for i in 0..<seq_len {
            sequence[i] = buf[i]
        }

        // If we only got the ESC so far, try to read the rest of the sequence
        if seq_len == 1 {
            for seq_len < len(sequence) {
                more, _ := os.read(os.stdin, sequence[seq_len:seq_len+1])
                if more <= 0 {
                    break
                }
                seq_len += more
            }
        }

        if seq_len == 1 {
            return Special_Key.Escape
        }

        seq := sequence[:seq_len]

        // Standard cursor keys: ESC [ A/B/C/D etc.
        if seq_len >= 3 && seq[1] == '[' {
            switch seq[2] {
            case 'A': return Special_Key.Up
            case 'B': return Special_Key.Down
            case 'C': return Special_Key.Right
            case 'D': return Special_Key.Left
            case 'H': return Special_Key.Home
            case 'F': return Special_Key.End
            case '3':
                if seq_len >= 4 && seq[3] == '~' do return Special_Key.Delete
            case '5':
                if seq_len >= 4 && seq[3] == '~' do return Special_Key.PageUp
            case '6':
                if seq_len >= 4 && seq[3] == '~' do return Special_Key.PageDown
            }
        }

        // Application cursor keys mode (some terminals): ESC O A/B/C/D
        if seq_len >= 3 && seq[1] == 'O' {
            switch seq[2] {
            case 'A': return Special_Key.Up
            case 'B': return Special_Key.Down
            case 'C': return Special_Key.Right
            case 'D': return Special_Key.Left
            case 'H': return Special_Key.Home
            case 'F': return Special_Key.End
            }
        }

        // Extended Home/End
        if seq_len >= 4 && seq[1] == '[' && seq[2] == '1' && seq[3] == '~' {
            return Special_Key.Home
        }
        if seq_len >= 4 && seq[1] == '[' && seq[2] == '4' && seq[3] == '~' {
            return Special_Key.End
        }

        return Unknown_Escape{}
    }

    // Fallback
    return rune(b)
}

// Helper to sleep a bit (for main loop pacing)
sleep_ms :: proc(ms: int) {
    time.sleep(time.Millisecond * time.Duration(ms))
}

// ============================================================================
// Resize handling (SIGWINCH)
// ============================================================================

SIGWINCH :: 28   // standard on Linux

// We store a global flag that main can check
resize_pending := false

// C signal handler
sigwinch_handler :: proc "c" (sig: posix.Signal) {
    resize_pending = true
}

// Install the resize signal handler (call once after init_terminal)
install_resize_handler :: proc() {
    act: posix.sigaction_t
    act.sa_handler = sigwinch_handler
    posix.sigemptyset(&act.sa_mask)
    act.sa_flags = {}

    posix.sigaction(cast(posix.Signal)SIGWINCH, &act, nil)
}

// Call this in the main loop or before draw when resize_pending is true
handle_pending_resize :: proc() -> bool {
    if !resize_pending do return false
    resize_pending = false
    update_terminal_size()
    return true
}
