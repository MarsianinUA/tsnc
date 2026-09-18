package fail_tests

import "core:strings"
import "core:testing"

import "../../../src/abi"
import "../../../src/runtime/fail"

@(test)
message_ends_with_the_source_location :: proc(t: ^testing.T) {
	site := abi.Fail_Site {
		file   = "main.ts",
		line   = 3,
		column = 5,
		error  = .Index_Out_Of_Range,
	}
	testing.expect_value(t, message(site), "error: index out of range at main.ts:3:5\n")
}

@(test)
message_without_a_file_has_no_location :: proc(t: ^testing.T) {
	testing.expect_value(t, message({error = .Out_Of_Memory}), "error: out of memory\n")
}

// assertion_failure passes the assertion prefix and message as detail parts.
@(test)
detail_parts_follow_the_error_name :: proc(t: ^testing.T) {
	site := abi.Fail_Site {
		file   = "console.odin",
		line   = 12,
		column = 7,
		error  = .Internal,
	}
	testing.expect_value(
		t,
		message(site, "panic", "boom"),
		"error: internal error: panic: boom at console.odin:12:7\n",
	)
}

@(test)
every_error_has_its_own_name :: proc(t: ^testing.T) {
	names: [abi.Runtime_Error]string
	for error in abi.Runtime_Error {
		line := message({error = error})
		names[error] = strings.trim_suffix(strings.trim_prefix(line, "error: "), "\n")
		testing.expectf(t, names[error] != "", "%v has an empty name", error)
		testing.expectf(t, names[error] != "unknown error", "%v has no name", error)
	}
	for name, error in names {
		for other, other_error in names {
			if other_error > error {
				testing.expectf(t, name != other, "%v and %v share %q", error, other_error, name)
			}
		}
	}
}

@(test)
value_outside_the_enum_is_an_unknown_error :: proc(t: ^testing.T) {
	testing.expect_value(t, message({error = abi.Runtime_Error(200)}), "error: unknown error\n")
}

message :: proc(site: abi.Fail_Site, detail: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	err := fail.write_message(strings.to_writer(&b), site, ..detail)
	assert(err == nil)
	return strings.to_string(b)
}
