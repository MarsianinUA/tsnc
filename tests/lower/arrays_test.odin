package lower_tests

import "core:slice"
import "core:testing"

import "../../src/abi"
import "../../src/ir"

// Arrays: literals, elements, the methods, the four loops lower builds around a callback, and
// for...of.

@(test)
a_literal_is_made_at_its_length_and_filled_through_checks :: proc(t: ^testing.T) {
	result := lower_text(t, "const xs = [1, 2, 3];\nconsole.log(xs);\n")
	init, _ := func_named(result.output, "init$m1")
	made := instructions_of(init, ir.New_Array)
	checks := instructions_of(init, ir.Bounds_Check)
	if !testing.expectf(t, len(made) == 1 && len(checks) == 3, "%s", result.text) {
		return
	}
	length, _ := number_at(init, made[0].length)
	testing.expect_value(t, length, 3)
	testing.expectf(t, len(instructions_of(init, ir.Element_Store)) == 3, "%s", result.text)
	// One literal, one place in the source: every check shares its two failure sites.
	for check in checks[1:] {
		testing.expect_value(t, check.not_integer, checks[0].not_integer)
		testing.expect_value(t, check.out_of_range, checks[0].out_of_range)
	}
}

@(test)
a_write_at_the_length_appends :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		"function put(a: string[], i: number, v: string): void {\na[i] = v;\n}\nput([\"a\"], 1, \"b\");\n",
	)
	body, _ := func_named(result.output, "m1.put")
	testing.expectf(t, len(instructions_of(body, ir.Length)) == 1, "%s", result.text)
	testing.expectf(t, calls_to(body, .Array_Push) == 1, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Bounds_Check)) == 1, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Element_Store_Ref)) == 1, "%s", result.text)
	compares := instructions_of(body, ir.Compare)
	testing.expect(t, len(compares) == 1 && compares[0].op == .Equal, "no test against the length")
}

@(test)
the_other_methods_are_runtime_calls :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function use(xs: number[]): void {
			const n = xs.push(1, 2);
			const last = xs.pop();
			const at = xs.indexOf(2);
			const has = xs.includes(3);
			const part = xs.slice(1);
			const text = xs.join();
			const sorted = xs.sort();
			console.log(n, last, at, has, part, text, sorted);
		}
		use([3, 1, 2]);
	`,
	)
	body, _ := func_named(result.output, "m1.use")
	exports := []abi.Runtime_Proc {
		.Array_Pop,
		.Array_Index_Of,
		.Array_Includes,
		.Array_Slice,
		.Array_Join,
		.Array_Sort_Default,
	}
	for export in exports {
		testing.expectf(t, calls_to(body, export) == 1, "%v:\n%s", export, result.text)
	}
	// Both items are evaluated before the first push, one push each.
	testing.expectf(t, calls_to(body, .Array_Push) == 2, "%s", result.text)
	for call in instructions_of(body, ir.Call_Runtime) {
		#partial switch call.export {
		case .Array_Slice:
			end, _ := number_at(body, call.args[2])
			testing.expect_value(t, end, f64(abi.MISSING_END))
		case .Array_Index_Of:
			from, _ := number_at(body, call.args[2])
			testing.expect_value(t, from, 0)
		case .Array_Join:
			_, is_constant := body.values[call.args[1]].variant.(ir.Const_String)
			testing.expect(t, is_constant, "join without a separator takes the constant \",\"")
		}
	}
}

@(test)
the_four_callback_methods_are_loops_with_the_callback_inlined :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function sum(xs: number[]): number {
			let total = 0;
			xs.forEach((x, i) => {
				if (i > 5) {
					return;
				}
				total += x;
			});
			const doubled = xs.map(x => x * 2);
			const big = xs.filter(x => {
				if (x > 2) {
					return true;
				}
				return false;
			});
			return total + doubled.length + big.length + xs.reduce((a, b) => a + b, 0);
		}
		console.log(sum([1, 2, 3]));
	`,
	)
	body, _ := func_named(result.output, "m1.sum")
	testing.expectf(t, len(instructions_of(body, ir.Call_Closure)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.New_Array)) == 2, "%s", result.text)
	testing.expectf(t, calls_to(body, .Array_Push) == 1, "%s", result.text)
	// A bare return in forEach ends the pass, not the function: the one Return is the function's.
	testing.expectf(t, len(instructions_of(body, ir.Return)) == 1, "%s", result.text)
	// The filter callback's two returns meet in a phi.
	bools := 0
	for instruction in body.values {
		_, is_phi := instruction.variant.(ir.Phi)
		bools += 1 if is_phi && instruction.type == ir.BOOL else 0
	}
	testing.expectf(t, bools == 1, "%s", result.text)
}

@(test)
a_callback_may_be_the_name_of_a_function :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function double(x: number): number {
			return x * 2;
		}
		console.log([1, 2].map(double));
	`,
	)
	init, _ := func_named(result.output, "init$m1")
	calls := instructions_of(init, ir.Call)
	if testing.expectf(t, len(calls) == 1, "%s", result.text) {
		testing.expect_value(t, len(calls[0].args), 1)
	}
}

@(test)
reduce_without_an_initial_value_fails_on_an_empty_array :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		"function total(xs: number[]): number {\nreturn xs.reduce((a, b) => a + b);\n}\ntotal([1]);\n",
	)
	body, _ := func_named(result.output, "m1.total")
	fails := instructions_of(body, ir.Fail)
	if testing.expectf(t, len(fails) == 1, "%s", result.text) {
		error := result.output.fail_sites[fails[0].site].error
		testing.expect_value(t, error, abi.Runtime_Error.Reduce_Of_Empty_Array)
	}
}

@(test)
for_of_walks_an_array_and_a_string_by_code_point :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function walk(xs: number[], text: string): number {
			let total = 0;
			for (const x of xs) {
				total += x;
			}
			for (const c of text) {
				total += c.length;
			}
			return total;
		}
		walk([1], "a");
	`,
	)
	body, _ := func_named(result.output, "m1.walk")
	testing.expectf(t, len(instructions_of(body, ir.Element_Load)) == 1, "%s", result.text)
	testing.expectf(t, calls_to(body, .String_Code_Point_At) == 1, "%s", result.text)
	// The string's index moves by the length of the code point it took.
	found := false
	for add in instructions_of(body, ir.Binary) {
		length, is_length := body.values[add.right].variant.(ir.Length)
		if add.op != .Add || !is_length {
			continue
		}
		call, is_call := body.values[length.value].variant.(ir.Call_Runtime)
		found ||= is_call && call.export == .String_Code_Point_At
	}
	testing.expectf(t, found, "%s", result.text)
}

@(test)
sorting_with_a_comparator_is_reported :: proc(t: ^testing.T) {
	result := expect_later(
		t,
		"const xs = [2, 1];\nconsole.log(xs.sort((a, b) => a - b));\n",
		{{.Not_Lowered, 2, 13}},
	)
	testing.expect(t, slice.equal(result.constructs, []string{"sorting with a comparator"}))
}
