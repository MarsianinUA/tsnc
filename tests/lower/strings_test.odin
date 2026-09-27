package lower_tests

import "core:testing"

import "../../src/ir"

// Strings: an index into one goes to the runtime, which checks it.

@(test)
an_index_into_a_string_is_checked_and_read_by_the_runtime :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		"function at(s: string, i: number): string {\nreturn s[i];\n}\nat(\"ab\", 1);\n",
	)
	body, _ := func_named(result.output, "m1.at")
	checks := instructions_of(body, ir.Bounds_Check)
	if !testing.expectf(t, len(checks) == 1, "%s", result.text) {
		return
	}
	testing.expect_value(t, checks[0].array, 0)
	for call in instructions_of(body, ir.Call_Runtime) {
		if call.export == .String_At {
			_, checked := body.values[call.args[1]].variant.(ir.Bounds_Check)
			testing.expect(t, checked, "String_At reads an index nothing checked")
		}
	}
	testing.expectf(t, calls_to(body, .String_At) == 1, "%s", result.text)
}
