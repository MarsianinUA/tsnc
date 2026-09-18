package target_tests

import "core:fmt"
import "core:strings"
import "core:testing"

import "../../src/target"

V1_TARGETS :: bit_set[target.Target]{.windows_amd64, .linux_amd64, .darwin_arm64, .darwin_amd64}

@(test)
parse_accepts_every_v1_name :: proc(t: ^testing.T) {
	for want in V1_TARGETS {
		name := target.NAMES[want]
		// The CLI name and the enum value share one spelling, so `%v` prints a valid -target: value.
		testing.expect_value(t, fmt.tprint(want), name)

		got, err := target.parse(name)
		testing.expect_value(t, err, target.Parse_Error.None)
		testing.expect_value(t, got, want)
	}
}

@(test)
parse_rejects_unknown_names :: proc(t: ^testing.T) {
	names := []string {
		"",
		"linux",
		"Linux_amd64",
		" linux_amd64",
		"linux_amd64 ",
		"x86_64-pc-linux-gnu",
		"windows_arm64",
	}
	for name in names {
		_, err := target.parse(name)
		testing.expectf(t, err == .Unknown, "parse(%q) returned %v", name, err)
	}
}

@(test)
parse_rejects_targets_without_a_row :: proc(t: ^testing.T) {
	_, err := target.parse("wasm32_wasi")
	testing.expect_value(t, err, target.Parse_Error.Unsupported)
	testing.expect(t, !target.supported(.wasm32_wasi))
}

@(test)
every_v1_target_has_a_complete_row :: proc(t: ^testing.T) {
	for id in target.Target {
		testing.expectf(
			t,
			target.supported(id) == (id in V1_TARGETS),
			"%v: supported is %v",
			id,
			target.supported(id),
		)
	}

	for id in V1_TARGETS {
		spec := target.SPECS[id]
		testing.expectf(t, len(spec.triple) > 0, "%v: empty triple", id)
		testing.expectf(t, len(spec.link_flags) > 0, "%v: no link flags", id)
		// link passes each element as one argument, so a space means two flags were merged.
		for flag in spec.link_flags {
			testing.expectf(
				t,
				flag != "" && !strings.contains_rune(flag, ' '),
				"%v: bad link flag %q",
				id,
				flag,
			)
		}
		// README builds the runtime object under this name.
		testing.expect_value(
			t,
			spec.runtime_object,
			fmt.tprintf("tsnc_rt-%s.obj", target.NAMES[id]),
		)
		testing.expectf(t, spec.pointer_size == 8, "%v: pointer size %d", id, spec.pointer_size)
	}
}

@(test)
host_is_a_v1_target :: proc(t: ^testing.T) {
	testing.expect(t, target.supported(target.HOST))
	testing.expect_value(t, target.SPECS[target.HOST].pointer_size, size_of(rawptr))
}
