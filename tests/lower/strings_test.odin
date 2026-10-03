package lower_tests

import "core:testing"

import "../../src/abi"
import "../../src/ir"
import "../harness"

// Strings: what reads a unit or compares without a call into the runtime.

@(test)
an_index_below_128_reads_a_static_cell_without_a_call :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function at(s: string, i: number): string {
			return s[i];
		}
		console.log(at("abc", 1));
	`,
	)
	body := harness.func_named(t, result.output, "m1.at")
	static, other, found := split_on_ascii(body)
	testing.expectf(t, found, "%s", result.text)
	testing.expectf(t, holds(body, static, ir.Ascii_Cell), "%s", result.text)
	testing.expectf(t, runtime_calls(body, static) == {}, "%s", result.text)
	testing.expectf(t, runtime_calls(body, other) == {.String_At}, "%s", result.text)
}

@(test)
a_step_of_for_of_below_128_reads_a_static_cell_without_a_call :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function units(s: string): number {
			let n = 0;
			for (const c of s) {
				n += c.length;
			}
			return n;
		}
		console.log(units("ab"));
	`,
	)
	body := harness.func_named(t, result.output, "m1.units")
	static, other, found := split_on_ascii(body)
	testing.expectf(t, found, "%s", result.text)
	testing.expectf(t, holds(body, static, ir.Ascii_Cell), "%s", result.text)
	testing.expectf(t, runtime_calls(body, static) == {}, "%s", result.text)
	testing.expectf(t, runtime_calls(body, other) == {.String_Code_Point_At}, "%s", result.text)
}

@(test)
a_literal_of_at_most_one_unit_compares_without_a_call :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function word(c: string): boolean {
			return c === "a" || c === "" || "b" !== c;
		}
		console.log(word("a"));
	`,
	)
	body := harness.func_named(t, result.output, "m1.word")
	testing.expectf(t, len(instructions_of(body, ir.Call_Runtime)) == 0, "%s", result.text)
}

@(test)
a_chain_of_plus_and_a_template_are_one_call_and_their_length_none :: proc(t: ^testing.T) {
	// Quoted: a backtick would end a raw string.
	result := lower_text(
		t,
		"function chain(a: string, b: string, n: number): string { return a + \":\" + b + n; }\n" +
		"function template(n: number): string { return `x${n}y${-n}z`; }\n" +
		"function size(a: string, b: string): number { return (a + \":\" + b).length; }\n",
	)
	for name in ([]string{"m1.chain", "m1.template"}) {
		body := harness.func_named(t, result.output, name)
		testing.expectf(t, calls_to(body, .String_Join) == 1, "%s", result.text)
		testing.expectf(t, len(instructions_of(body, ir.Call_Runtime)) == 1, "%s", result.text)
	}
	size := harness.func_named(t, result.output, "m1.size")
	testing.expectf(t, len(instructions_of(size, ir.Call_Runtime)) == 0, "%s", result.text)
}

@(test)
the_runtime_compares_two_strings_only_after_identity_and_length :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function same(a: string, b: string): boolean {
			return a === b;
		}
		console.log(same("a", "b"));
	`,
	)
	body := harness.func_named(t, result.output, "m1.same")
	one_cell, found := branch_on(body, ir.Same_Cell{a = 0, b = 1})
	testing.expectf(t, found, "%s", result.text)
	lengths, is_branch := terminator(body, one_cell.else_block).(ir.Branch)
	testing.expectf(t, is_branch, "%s", result.text)
	if !found || !is_branch {
		return
	}
	test, is_compare := body.values[lengths.condition].variant.(ir.Compare)
	testing.expectf(t, is_compare && test.op == .Equal, "%s", result.text)
	_, left_is_length := body.values[test.left].variant.(ir.Length)
	_, right_is_length := body.values[test.right].variant.(ir.Length)
	testing.expectf(t, left_is_length && right_is_length, "%s", result.text)
	for _, block in body.blocks {
		calls := runtime_calls(body, ir.Block_ID(block))
		testing.expectf(
			t,
			calls == ({.String_Equal} if ir.Block_ID(block) == lengths.then_block else {}),
			"%s",
			result.text,
		)
	}
}

@(private = "file")
split_on_ascii :: proc(body: ir.Func) -> (below, other: ir.Block_ID, found: bool) {
	for branch in instructions_of(body, ir.Branch) {
		test, is_compare := body.values[branch.condition].variant.(ir.Compare)
		if !is_compare || test.op != .Less {
			continue
		}
		_, is_unit := body.values[test.left].variant.(ir.Unit_Load)
		limit, is_constant := body.values[test.right].variant.(ir.Const_Number)
		if is_unit && is_constant && limit.value == ir.ASCII_LIMIT {
			return branch.then_block, branch.else_block, true
		}
	}
	return
}

@(private = "file")
branch_on :: proc(body: ir.Func, condition: ir.Same_Cell) -> (ir.Branch, bool) {
	for branch in instructions_of(body, ir.Branch) {
		test, is_test := body.values[branch.condition].variant.(ir.Same_Cell)
		if is_test && test == condition {
			return branch, true
		}
	}
	return {}, false
}

@(private = "file")
terminator :: proc(body: ir.Func, block: ir.Block_ID) -> ir.Variant {
	instructions := body.blocks[block].instructions
	return body.values[instructions[len(instructions) - 1]].variant
}

@(private = "file")
holds :: proc(body: ir.Func, block: ir.Block_ID, $T: typeid) -> bool {
	for value in body.blocks[block].instructions {
		if _, is_variant := body.values[value].variant.(T); is_variant {
			return true
		}
	}
	return false
}

@(private = "file")
runtime_calls :: proc(body: ir.Func, block: ir.Block_ID) -> (calls: bit_set[abi.Runtime_Proc]) {
	for value in body.blocks[block].instructions {
		if call, is_call := body.values[value].variant.(ir.Call_Runtime); is_call {
			calls += {call.export}
		}
	}
	return
}
