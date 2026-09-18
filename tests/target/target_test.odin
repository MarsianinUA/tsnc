package target_tests

import "core:fmt"
import "core:strings"
import "core:testing"

import "../../src/target"

V1_TARGETS :: bit_set[target.Target]{.windows_amd64, .linux_amd64, .darwin_arm64, .darwin_amd64}

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
		// README builds the runtime object under this name, with the `-target:` spelling.
		testing.expect_value(t, spec.runtime_object, fmt.tprintf("tsnc_rt-%v.obj", id))
		testing.expectf(t, spec.pointer_size == 8, "%v: pointer size %d", id, spec.pointer_size)
	}
}

@(test)
host_is_a_v1_target :: proc(t: ^testing.T) {
	testing.expect(t, target.supported(target.HOST))
	testing.expect_value(t, target.SPECS[target.HOST].pointer_size, size_of(rawptr))
}
