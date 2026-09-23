package abi_tests

import "core:strings"
import "core:testing"

import "../../src/abi"

// Generated code and the runtime link together with libc and the Odin runtime, so their shared
// symbols live under one prefix.
@(test)
symbols_start_with_tsnc_prefix :: proc(t: ^testing.T) {
	testing.expectf(
		t,
		strings.has_prefix(abi.MAIN_SYMBOL, "tsnc_"),
		"main symbol %q",
		abi.MAIN_SYMBOL,
	)
	exports := abi.RUNTIME_EXPORTS
	for export, id in exports {
		testing.expectf(
			t,
			strings.has_prefix(export.symbol, "tsnc_"),
			"%v symbol %q",
			id,
			export.symbol,
		)
	}
}

// Readers index SLOT_SIZE by the slot kind of a field, a value known only at run time.
@(test)
slot_size_is_indexed_by_a_variable :: proc(t: ^testing.T) {
	for kind in abi.Slot_Kind {
		want := size_of(abi.Tagged) if kind == .Tagged else 8
		testing.expectf(t, abi.SLOT_SIZE[kind] == want, "%v: %d bytes", kind, abi.SLOT_SIZE[kind])
	}
}

@(test)
symbols_are_distinct :: proc(t: ^testing.T) {
	exports := abi.RUNTIME_EXPORTS
	for export, id in exports {
		testing.expectf(t, export.symbol != abi.MAIN_SYMBOL, "%v reuses the main symbol", id)
		for other, other_id in exports {
			if other_id > id {
				testing.expectf(
					t,
					export.symbol != other.symbol,
					"%v and %v share %q",
					id,
					other_id,
					export.symbol,
				)
			}
		}
	}
}

// codegen passes a Rest as the last two arguments of the call and the runtime reads it as the tail
// of its parameter list, so nothing may follow it.
@(test)
rest_is_only_the_last_parameter :: proc(t: ^testing.T) {
	exports := abi.RUNTIME_EXPORTS
	for export, id in exports {
		testing.expectf(t, export.result != .Rest, "%v answers a Rest", id)
		for param, i in export.params {
			if param == .Rest {
				testing.expectf(t, i == len(export.params) - 1, "%v has a Rest before the end", id)
			}
		}
	}
}
