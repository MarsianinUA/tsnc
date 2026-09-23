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

// A C function returns a 16-byte struct through a hidden pointer on Win64 and in two registers on
// SysV and arm64, and codegen declares no such result.
@(test)
no_export_returns_a_tagged_value :: proc(t: ^testing.T) {
	exports := abi.RUNTIME_EXPORTS
	for export, id in exports {
		testing.expectf(t, export.result != .Tagged, "%v returns a tagged value", id)
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
