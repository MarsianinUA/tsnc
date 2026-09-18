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
