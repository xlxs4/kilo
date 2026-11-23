// I got some TODOs for today:
// - [x] look into -vet and strict mode
// - [x] stop using GitHub master for docs, use the local installation
// - [x] see if we can get rid of the ugly transmute
// - [x] fix the memory leaks in repeat/concatenate
// - [x] escape sequences as constants
// - [x] figure out what the correct alternative to the dynamic buffer is
// - [ ] look into the builtin allocators
// - [ ] should I explicitly pass pointers? (yes)
// - [ ] look into delete, free_all, and how to trace memory
// - [ ] defer vs atexit
// - [ ] no more os/psx.exit
// - [x] string concat with +
// - [ ] unicode.is_control
// - [ ] better error handling
// - [x] u8 vs byte (read_key)
// - [ ] consider moving stuff out of main
// - [ ] maybe read about stuff
// - [ ] assert vs ensure vs proper err handling

package kilo

import "core:fmt"
import "core:io"
import "core:os"
import str "core:strings"
import "core:unicode"

import "core:sys/linux"
import psx "core:sys/posix"

VERSION :: "0.0.1"
WELCOME_MSG :: "Kilo editor -- version "

// Escape sequences
// https://vt100.net/docs/vt100-ug/contents.html
// There's also core:terminal/ansi if you're into that
CLEAR_SCREEN :: "\x1b[2J"
CLEAR_LINE_AFTER_CURSOR :: "\x1b[K"
CURSOR_TOP_LEFT :: "\x1b[H"
CURSOR_TO_COORDS :: "\x1b[%d;%dH"
CURSOR_VISIBLE :: "\x1b[?25h"
CURSOR_INVISIBLE :: "\x1b[?25l"

// TODO: Enum
ESC :: 0x1b
ARROW_UP :: 1000
ARROW_DOWN :: 1001
ARROW_LEFT :: 1002
ARROW_RIGHT :: 1003
HOME_KEY :: 1004
END_KEY :: 1005
PAGE_UP :: 1006
PAGE_DOWN :: 1007
DEL_KEY :: 1008

// In the terminal, pressing ctrl+key strips the upper 3 bits of the byte
// representation of the key, and sends that. You can use this proc to
// get the byte of a key if pressed after a ctrl
CTRL_Q :: 'Q' & 0x1f

// TODO: Move builder here?
State :: struct {
	in_stream: io.Stream,   // Stream to STDIN
	orig_term: psx.termios, // To remember original terminal state
	
	n_cols: int,
	n_rows: int,

	cursor_x: int,
	cursor_y: int,
}

g_state: State

enable_raw_mode :: proc() {
	// Grab current terminal state
	if psx.tcgetattr(psx.STDIN_FILENO, &g_state.orig_term) != .OK {
		fmt.eprintfln("tcgetattr failure: %s", psx.strerror(psx.errno()))
		// TODO: clear_screen() here?
		psx.exit(1)
	}
	// Make sure to cleanup
	psx.atexit(disable_raw_mode)
	raw := g_state.orig_term
	// Remove
	//  ICRNL:  so that carriage return ('\r') isn't translated to newline ('\n')
	//  IXON:   so that XON/XOFF (Ctrl+S/Ctrl+Q) don't generate signals
	//	 ECHO:   so that what we type into the terminal isn't printed on screen
	//  ICANON: so that we get each input byte separately instead of whole line at once
	//          (disable canonical mode)
	//  IEXTEN: so that Ctrl+V doesn't get special treatment
	//  ISIG:   so that INT, QUIT, SUSP, DSUSP (e.g., Ctrl+C/Ctrl+Z) don't generate signals
	//  OPOST:  so that newline ('\n') isn't translated to newline + carriage return ("\n\r")
	//          (disable output processing)
	//  BRKINT, INPCK, ISTRIP: more ancient stuff
	// Add
	//  CS8: so that character size is 8 bits per size (also ancient stuff)
	raw.c_cflag += {.CS8}
	raw.c_iflag -= {.BRKINT, .ICRNL, .INPCK, .ISTRIP, .IXON}
	raw.c_lflag -= {.ECHO, .ICANON, .IEXTEN, .ISIG}
	raw.c_oflag -= {.OPOST}
	// Let's give the terminal read a timeout so it isn't indefinitely blocking.
	// We set VMIN to 0 so that there's no minimum number of characters
	// for a read,
	raw.c_cc[.VMIN] = 0
	// and VTIME so that read has a timeout of 0.1 seconds (VTIME is in deciseconds)
	raw.c_cc[.VTIME] = 1
	// TCSANOW applies the change immediately
	if psx.tcsetattr(psx.STDIN_FILENO, .TCSANOW, &raw) != .OK {
		fmt.eprintfln("tcsetattr failure: %s", psx.strerror(psx.errno()))
		psx.exit(1)
	}
}

disable_raw_mode :: proc "c" () {
	psx.tcsetattr(psx.STDIN_FILENO, .TCSANOW, &g_state.orig_term)
}

init :: proc() {
	g_state.in_stream = os.to_stream(os.stdin)
	// We should just be able to call get_terminal_size(), which is merged upstream
	// but not yet in an Odin release:
	// w, h, ok := terminal.get_terminal_size()

	// Here's the linux version (core/terminal/terminal_linux.odin):
	Winsize :: struct {
		row, col, xpixel, ypixel: u16,
	}

	ws: Winsize

	// We could also use "\x1b[999C\x1b[999B" to reposition the cursor to the bottom
	// right corner of the screen, and manually calculate the number of cols and rows,
	// if the device doesn't support ioctl, but eh.
	if linux.ioctl(psx.STDOUT_FILENO, linux.TIOCGWINSZ, uintptr(&ws)) == 0 {
		w := int(ws.col)
		h := int(ws.row)
		ensure(w > 0 && h > 0)
		g_state.n_cols, g_state.n_rows = w, h
	} else {
		fmt.eprintfln("ioctl failure: %s", psx.strerror(psx.errno()))
		// TODO: clear_screen() here?
		psx.exit(1)
	}
}

// Adapted from core/unicode/letter.odin.
// We could also use iscntrl from libc, or unicode.is_control(rune(x))
is_control :: proc(b: byte) -> bool #no_bounds_check {
	pC :: 1<<0 // a control character
	return unicode.char_properties[b] & pC != 0
}

read_key :: proc() -> (key: int, ok: bool) {
	c, err := io.read_byte(g_state.in_stream)
	// read_byte errors when there's no data to read (EOF).
	// We don't treat EOF as an error, since we've set
	// VMIN to 0 and VTIME to 1 in enable_raw_mode
	if err != nil && err!= .EOF {
		// TODO: what should I return in place of ESC?
		// TODO: should I name byte return?
		return ESC, false
	}
	if (c == ESC) {
		seq0, err0 := io.read_byte(g_state.in_stream)
		if err0 != nil {
			if err0 == .EOF {
				return ESC, true
			}
			return ESC, false
		}
		seq1, err1 := io.read_byte(g_state.in_stream)
		if err1 != nil {
			if err1 == .EOF {
				return ESC, true
			}
			return ESC, false
		}
		if seq0 == '[' {
			if seq1 >= '0' && seq1 <= '9' {
				seq2, err2 := io.read_byte(g_state.in_stream)
				if err2 != nil {
					if err2 == .EOF {
						return ESC, true
					}
					return ESC, false
				}
				if seq2 == '~' {
					switch seq1 {
					case '1': return HOME_KEY, true
					case '3': return DEL_KEY, true
					case '4': return END_KEY, true
					case '5': return PAGE_UP, true
					case '6': return PAGE_DOWN, true
					case '7': return HOME_KEY, true
					case '8': return END_KEY, true
					}
				}
			} else
			{
				switch seq1 {
				case 'A': return ARROW_UP, true
				case 'B': return ARROW_DOWN, true
				case 'C': return ARROW_RIGHT, true
				case 'D': return ARROW_LEFT, true
				case 'H': return HOME_KEY, true
				case 'F': return END_KEY, true
				}
			}
		} else if seq0 == 'O' {
			switch seq1 {
			case 'H': return HOME_KEY, true
			case 'F': return END_KEY, true
			}
		}
		return ESC, true
	}
	return int(c), true
}

move_cursor :: proc(key: int) {
	switch key {
	case ARROW_LEFT:
		if g_state.cursor_x > 0 {
			g_state.cursor_x -= 1
		}
	case ARROW_DOWN:
		if g_state.cursor_y < g_state.n_rows {
			g_state.cursor_y += 1
		}
	case ARROW_UP:
		if g_state.cursor_y > 0 {
			g_state.cursor_y -= 1
		}
	case ARROW_RIGHT:
		if g_state.cursor_x < g_state.n_cols {
			g_state.cursor_x += 1
		}
	}
}

process_keypress :: proc() -> bool {
	keep_running := true
	b, ok := read_key()
	if ok {
		switch b {
		// Ctrl+Q to exit
		case CTRL_Q: keep_running = false
		case ARROW_LEFT: fallthrough
		case ARROW_DOWN: fallthrough
		case ARROW_UP: fallthrough
		case ARROW_RIGHT: move_cursor(b)
		case HOME_KEY: g_state.cursor_x = 0
		case END_KEY: g_state.cursor_x = g_state.n_cols - 1
		case PAGE_UP:
			{
				for _ in 0..<g_state.n_rows {
					move_cursor(ARROW_UP)
				}
			}
		case PAGE_DOWN:
			{
				for _ in 0..<g_state.n_rows {
					move_cursor(ARROW_DOWN)
				}
			}
		}
	} else {
		keep_running = false
	}
	return keep_running
}

refresh_screen :: proc() {
	sb := str.builder_make()
	defer(str.builder_destroy(&sb))

	str.write_string(&sb, CURSOR_INVISIBLE)
	str.write_string(&sb, CURSOR_TOP_LEFT)

	draw_rows(&sb)

	// cursor_x/cursor_y are 0-indexed, so we +1
	fmt.sbprintf(&sb, CURSOR_TO_COORDS, g_state.cursor_y+1, g_state.cursor_x+1)
	str.write_string(&sb, CURSOR_VISIBLE)
	// TODO: error handling
	os.write(os.stdout, sb.buf[:])
}

draw_rows :: proc(sb: ^str.Builder) {
	for row in 1..<g_state.n_rows {
		if row == g_state.n_rows/3 {
			msg_len := len(WELCOME_MSG) + len(VERSION)
			// Center welcome message
			pad := (g_state.n_cols - msg_len) / 2
			str.write_byte(sb, '~')
			for _ in 1..<pad {
				str.write_byte(sb, ' ')
			}
			fmt.sbprintf(sb, "%s%s\r\n", WELCOME_MSG, VERSION)
		} else {
			str.write_string(sb, "~\r\n")
		}
		str.write_string(sb, CLEAR_LINE_AFTER_CURSOR)
	}
	str.write_byte(sb, '~')
	str.write_string(sb, CLEAR_LINE_AFTER_CURSOR)
}

main :: proc() {
	enable_raw_mode()
	init()
	for {
		refresh_screen()
		if !process_keypress() {
			os.write_string(os.stdout, string(CLEAR_SCREEN + CURSOR_TOP_LEFT))
			break
		}
	}
}
