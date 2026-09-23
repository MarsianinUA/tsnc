package console_tests

import "core:testing"

import "../../../src/runtime/console"

// getColorDepth of lib/internal/tty.js, which Node exposes to --expose-internals; the platform is
// pinned first, since the function reads it:
//
//	node --expose-internals -e "Object.defineProperty(process, 'platform', { value: 'linux' }); console.log(require('internal/tty').getColorDepth({ TERM: 'xterm' }))"
@(test)
color_depth_matches_node :: proc(t: ^testing.T) {
	// color_depth lowercases TERM in context.allocator, the scratch arena of an export.
	context.allocator = context.temp_allocator
	cases := [?]struct {
		environment: []string,
		other:       int, // on Linux and macOS
		windows:     int,
	} {
		{{}, 1, 24},
		{{"FORCE_COLOR="}, 4, 4},
		{{"FORCE_COLOR=1"}, 4, 4},
		{{"FORCE_COLOR=true"}, 4, 4},
		{{"FORCE_COLOR=2"}, 8, 8},
		{{"FORCE_COLOR=3"}, 24, 24},
		{{"FORCE_COLOR=0"}, 1, 1},
		{{"FORCE_COLOR=yes"}, 1, 1},
		{{"FORCE_COLOR=1", "NO_COLOR=1"}, 4, 4},
		// An empty NO_COLOR or NODE_DISABLE_COLORS disables nothing.
		{{"NO_COLOR="}, 1, 24},
		{{"NO_COLOR=1"}, 1, 1},
		{{"NODE_DISABLE_COLORS=1"}, 1, 1},
		{{"NODE_DISABLE_COLORS="}, 1, 24},
		{{"TERM=dumb"}, 1, 1},
		{{"TMUX=1"}, 24, 24},
		{{"TMUX="}, 1, 24},
		{{"TF_BUILD=", "AGENT_NAME=x"}, 4, 24},
		{{"CI="}, 1, 24},
		{{"CI=1", "GITHUB_ACTIONS="}, 24, 24},
		{{"CI=1", "TRAVIS=1"}, 8, 24},
		{{"CI=1", "CI_NAME=codeship"}, 8, 24},
		{{"TEAMCITY_VERSION=9.1.0"}, 4, 24},
		{{"TEAMCITY_VERSION=9.0.1"}, 1, 24},
		{{"TEAMCITY_VERSION=10.0"}, 4, 24},
		{{"TEAMCITY_VERSION=8.1.0"}, 1, 24},
		{{"TEAMCITY_VERSION=9.01.2"}, 4, 24},
		{{"TEAMCITY_VERSION=9.00.2"}, 1, 24},
		{{"TERM_PROGRAM=iTerm.app"}, 8, 24},
		{{"TERM_PROGRAM=iTerm.app", "TERM_PROGRAM_VERSION=3.4"}, 24, 24},
		{{"TERM_PROGRAM=iTerm.app", "TERM_PROGRAM_VERSION=2.9"}, 8, 24},
		{{"TERM_PROGRAM=Apple_Terminal"}, 8, 24},
		{{"TERM_PROGRAM=HyperTerm"}, 24, 24},
		{{"COLORTERM=truecolor"}, 24, 24},
		{{"COLORTERM=24bit"}, 24, 24},
		{{"COLORTERM=1"}, 4, 24},
		{{"TERM=xterm-truecolor"}, 24, 24},
		{{"TERM=xterm-256color"}, 8, 24},
		{{"TERM=Xterm-256color"}, 4, 24},
		{{"TERM=xterm"}, 4, 24},
		{{"TERM=screen.xterm"}, 4, 24},
		{{"TERM=Konsole"}, 4, 24},
		{{"TERM=mosh"}, 24, 24},
		{{"TERM=con132x25"}, 4, 24},
		{{"TERM=conx"}, 1, 24},
		{{"TERM=linux"}, 4, 24},
		{{"TERM=my-ansi"}, 4, 24},
		{{"TERM=vt220"}, 4, 24},
		{{"TERM=unknown"}, 1, 24},
		{{"TERM=unknown", "COLORTERM=x"}, 4, 24},
	}
	for c in cases {
		other := console.color_depth(c.environment, .Other)
		testing.expectf(
			t,
			other == c.other,
			"%v elsewhere: %d, want %d",
			c.environment,
			other,
			c.other,
		)
		windows := console.color_depth(c.environment, .Windows)
		testing.expectf(
			t,
			windows == c.windows,
			"%v on Windows: %d, want %d",
			c.environment,
			windows,
			c.windows,
		)
	}
	// process.env matches names without regard to case on Windows only.
	lower := []string{"force_color=0"}
	testing.expect_value(t, console.color_depth(lower, .Windows), 1)
	testing.expect_value(t, console.color_depth(lower, .Other), 1)
	testing.expect_value(t, console.color_depth([]string{"term=xterm"}, .Other), 1)
}
