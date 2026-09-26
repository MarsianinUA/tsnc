package console

import "core:os"
import "core:strings"

/*
Colors, as Node decides them for console.log: shouldColorize of lib/internal/util/colors.js, which
asks getColorDepth of lib/internal/tty.js, and the styles of util.inspect. FORCE_COLOR decides
alone, whatever the stream is, which is how a test sees colors through a pipe; otherwise the stream
must be a terminal, and the environment must allow more than two colors.

The decision is made at every call: the runtime keeps no state, and the environment is read only
when FORCE_COLOR is set or the stream is a terminal.
*/

Color_Host :: enum u8 {
	Windows,
	Other,
}

when ODIN_OS == .Windows {
	@(private)
	HOST :: Color_Host.Windows
} else {
	@(private)
	HOST :: Color_Host.Other
}

// The depths getColorDepth answers, in bits.
@(private)
COLORS_2 :: 1
@(private)
COLORS_16 :: 4
@(private)
COLORS_256 :: 8
@(private)
COLORS_16M :: 24

should_colorize :: proc(stream: Stream) -> bool {
	colors := false
	force, forced := os.lookup_env("FORCE_COLOR", context.allocator)
	when ODIN_OS == .Windows {
		forced ||= force_color_set()
	}
	if forced {
		colors = forced_depth(force) > COLORS_2
	} else if is_terminal(stream) {
		environment, _ := os.environ(context.allocator)
		colors = color_depth(environment, HOST) > COLORS_2
	}
	when ODIN_OS == .Windows {
		if colors {
			enable_console_escapes(stream)
		}
	}
	return colors
}

// color_depth is getColorDepth: 1, 4, 8 or 24 bits, where 1 means no colors. `environment` holds
// NAME=value entries, as os.environ answers them, and a name matches without regard to case on
// Windows, as in process.env there. Every Windows answers more than 16 colors: Node asks the build
// number only to pick between 256 and 16 million.
color_depth :: proc(environment: []string, host: Color_Host) -> int {
	if force, forced := lookup(environment, "FORCE_COLOR", host); forced {
		return forced_depth(force)
	}
	if lookup_non_empty(environment, "NODE_DISABLE_COLORS", host) ||
	   lookup_non_empty(environment, "NO_COLOR", host) {
		return COLORS_2
	}
	term, _ := lookup(environment, "TERM", host)
	if term == "dumb" {
		return COLORS_2
	}
	if host == .Windows {
		return COLORS_16M
	}
	if lookup_non_empty(environment, "TMUX", host) {
		return COLORS_16M
	}
	_, azure := lookup(environment, "TF_BUILD", host)
	_, agent := lookup(environment, "AGENT_NAME", host)
	if azure && agent {
		return COLORS_16
	}
	if _, ci := lookup(environment, "CI", host); ci {
		CI_ENVS :: [?]struct {
			name:  string,
			depth: int,
		} {
			{"APPVEYOR", COLORS_256},
			{"BUILDKITE", COLORS_256},
			{"CIRCLECI", COLORS_16M},
			{"DRONE", COLORS_256},
			{"GITEA_ACTIONS", COLORS_16M},
			{"GITHUB_ACTIONS", COLORS_16M},
			{"GITLAB_CI", COLORS_256},
			{"TRAVIS", COLORS_256},
		}
		for ci_env in CI_ENVS {
			if _, found := lookup(environment, ci_env.name, host); found {
				return ci_env.depth
			}
		}
		name, _ := lookup(environment, "CI_NAME", host)
		return COLORS_256 if name == "codeship" else COLORS_2
	}
	if version, teamcity := lookup(environment, "TEAMCITY_VERSION", host); teamcity {
		return COLORS_16 if is_teamcity_with_colors(version) else COLORS_2
	}
	program, _ := lookup(environment, "TERM_PROGRAM", host)
	switch program {
	case "iTerm.app":
		version, _ := lookup(environment, "TERM_PROGRAM_VERSION", host)
		old := len(version) >= 2 && '0' <= version[0] && version[0] <= '2' && version[1] == '.'
		return COLORS_256 if version == "" || old else COLORS_16M
	case "HyperTerm", "MacTerm":
		return COLORS_16M
	case "Apple_Terminal":
		return COLORS_256
	}
	colorterm, _ := lookup(environment, "COLORTERM", host)
	if colorterm == "truecolor" || colorterm == "24bit" {
		return COLORS_16M
	}
	if term != "" {
		if strings.contains(term, "truecolor") {
			return COLORS_16M
		}
		if strings.has_prefix(term, "xterm-256") {
			return COLORS_256
		}
		if depth := term_depth(strings.to_lower(term, context.allocator)); depth != 0 {
			return depth
		}
	}
	return COLORS_16 if colorterm != "" else COLORS_2
}

// forced_depth reads FORCE_COLOR. Node also warns once that NO_COLOR or NODE_DISABLE_COLORS is
// ignored then; that warning carries a process id, and is not written.
@(private)
forced_depth :: proc(force: string) -> int {
	switch force {
	case "", "1", "true":
		return COLORS_16
	case "2":
		return COLORS_256
	case "3":
		return COLORS_16M
	}
	return COLORS_2
}

// term_depth is the TERM table of lib/internal/tty.js, then its patterns, on the lowercase name;
// 0 when neither knows it.
@(private)
term_depth :: proc(term: string) -> int {
	switch term {
	case "eterm",
	     "cons25",
	     "console",
	     "cygwin",
	     "dtterm",
	     "gnome",
	     "hurd",
	     "jfbterm",
	     "konsole",
	     "kterm",
	     "mlterm",
	     "putty",
	     "st":
		return COLORS_16
	case "mosh", "rxvt-unicode-24bit", "terminator", "xterm-kitty":
		return COLORS_16M
	}
	for part in ([?]string{"ansi", "color", "linux", "direct"}) {
		if strings.contains(term, part) {
			return COLORS_16
		}
	}
	for prefix in ([?]string{"rxvt", "screen", "xterm", "vt100", "vt220"}) {
		if strings.has_prefix(term, prefix) {
			return COLORS_16
		}
	}
	// /^con[0-9]*x[0-9]/
	if strings.has_prefix(term, "con") {
		at := len("con")
		for at < len(term) && '0' <= term[at] && term[at] <= '9' {
			at += 1
		}
		if at + 1 < len(term) && term[at] == 'x' && '0' <= term[at + 1] && term[at + 1] <= '9' {
			return COLORS_16
		}
	}
	return 0
}

// is_teamcity_with_colors is /^(9\.(0*[1-9]\d*)\.|\d{2,}\.)/: TeamCity 9.1 and later.
@(private)
is_teamcity_with_colors :: proc(version: string) -> bool {
	digits := 0
	for digits < len(version) && '0' <= version[digits] && version[digits] <= '9' {
		digits += 1
	}
	if digits >= 2 {
		return digits < len(version) && version[digits] == '.'
	}
	if digits != 1 || version[0] != '9' || len(version) < 2 || version[1] != '.' {
		return false
	}
	minor := version[2:]
	width := 0
	nonzero := false
	for width < len(minor) && '0' <= minor[width] && minor[width] <= '9' {
		nonzero ||= minor[width] != '0'
		width += 1
	}
	return nonzero && width < len(minor) && minor[width] == '.'
}

@(private)
lookup :: proc(
	environment: []string,
	name: string,
	host: Color_Host,
) -> (
	value: string,
	found: bool,
) {
	for entry in environment {
		key, _, rest := strings.partition(entry, "=")
		same := strings.equal_fold(key, name) if host == .Windows else key == name
		if same && len(key) > 0 {
			return rest, true
		}
	}
	return "", false
}

@(private)
lookup_non_empty :: proc(environment: []string, name: string, host: Color_Host) -> bool {
	value, found := lookup(environment, name, host)
	return found && value != ""
}

// is_terminal answers stream.isTTY.
@(private)
is_terminal :: proc(stream: Stream) -> bool {
	when ODIN_OS == .Windows {
		return is_console(stream)
	} else {
		return os.is_tty(file_of(stream))
	}
}

// Style is a style of util.inspect.styles, with the codes of util.inspect.colors that color it.
@(private)
Style :: enum u8 {
	Special, // cyan
	Number, // yellow
	Boolean, // yellow
	Undefined, // grey
	Null, // bold
	String, // green
}

@(private, rodata)
STYLE_CODES := [Style][2]string {
	.Special   = {"36", "39"},
	.Number    = {"33", "39"},
	.Boolean   = {"33", "39"},
	.Undefined = {"90", "39"},
	.Null      = {"1", "22"},
	.String    = {"32", "39"},
}

@(private)
open_style :: proc(colors: bool, out: ^[dynamic]u16, style: Style) {
	if colors {
		append_ascii(out, "\x1b[")
		append_ascii(out, STYLE_CODES[style][0])
		append(out, 'm')
	}
}

@(private)
close_style :: proc(colors: bool, out: ^[dynamic]u16, style: Style) {
	if colors {
		append_ascii(out, "\x1b[")
		append_ascii(out, STYLE_CODES[style][1])
		append(out, 'm')
	}
}

@(private)
styled :: proc(colors: bool, out: ^[dynamic]u16, text: string, style: Style) {
	open_style(colors, out, style)
	append_ascii(out, text)
	close_style(colors, out, style)
}
