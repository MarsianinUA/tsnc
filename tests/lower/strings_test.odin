package lower_tests

import "core:testing"

import "../../src/abi"
import "../../src/ir"

// Strings: their length, joining, templates, comparisons, indexing and the methods of the lib.

@(test)
joining_turns_each_operand_into_a_string :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function join(s: string, n: number, b: boolean, xs: number[]): string {
			return s + n + b + xs;
		}
		join("a", 1, true, [2]);
	`,
	)
	body, _ := func_named(result.output, "m1.join")
	testing.expectf(t, calls_to(body, .String_Concat) == 3, "%s", result.text)
	testing.expectf(t, calls_to(body, .Number_To_String) == 1, "%s", result.text)
	// A boolean goes through the conversion that answers Node's words, an array through the one `+`
	// asks, which asks an object for its valueOf first.
	testing.expectf(t, calls_to(body, .Value_To_String) == 1, "%s", result.text)
	testing.expectf(t, calls_to(body, .Value_To_Primitive_String) == 1, "%s", result.text)
}

@(test)
a_template_joins_its_parts_in_order :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		"function greet(name: string, n: number): string {\nreturn `hi ${name}, ${n}!`;\n}\n" +
		"greet(\"a\", 1);\n",
	)
	body, _ := func_named(result.output, "m1.greet")
	// "hi " + name, + ", ", + n, + "!"
	testing.expectf(t, calls_to(body, .String_Concat) == 4, "%s", result.text)
	testing.expectf(t, calls_to(body, .Number_To_String) == 1, "%s", result.text)
}

@(test)
a_comparison_of_strings_goes_by_the_runtime :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function order(a: string, b: string): boolean[] {
			return [a === b, a !== b, a < b, a > b, a <= b, a >= b];
		}
		order("a", "b");
	`,
	)
	body, _ := func_named(result.output, "m1.order")
	testing.expectf(t, calls_to(body, .String_Equal) == 2, "%s", result.text)
	testing.expectf(t, calls_to(body, .String_Less) == 4, "%s", result.text)
	// !==, <= and >= are the negation of another question.
	nots := 0
	for unary in instructions_of(body, ir.Unary) {
		nots += 1 if unary.op == .Not else 0
	}
	testing.expectf(t, nots == 3, "%s", result.text)
}

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

@(test)
a_method_passes_the_stand_in_of_an_argument_left_out :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function use(s: string, n: number): void {
			console.log(s.length, s.slice(1), s.split(","), s.indexOf("x"), s.includes("y"));
			console.log(s.charCodeAt(0), s.endsWith("z"), n.toFixed(), n.toString(), s.trim());
			console.log(String(), String(n), Number.parseFloat(s));
		}
		use("a,b", 1.5);
	`,
	)
	body, _ := func_named(result.output, "m1.use")
	testing.expectf(t, len(instructions_of(body, ir.Length)) == 1, "%s", result.text)
	stand_ins := []struct {
		export: abi.Runtime_Proc,
		arg:    int,
		value:  f64,
	} {
		{.String_Slice, 2, abi.MISSING_END},
		{.String_Split, 2, abi.MISSING_LIMIT},
		{.String_Index_Of, 2, 0},
		{.String_Ends_With, 2, abi.MISSING_END},
		{.Number_To_Fixed, 1, 0},
	}
	for want in stand_ins {
		found := false
		for call in instructions_of(body, ir.Call_Runtime) {
			if call.export != want.export {
				continue
			}
			value, is_number := number_at(body, call.args[want.arg])
			found = is_number && value == want.value
		}
		testing.expectf(t, found, "%v does not pass %v:\n%s", want.export, want.value, result.text)
	}
	// includes is indexOf and a comparison with -1, so there are two indexOf calls in all.
	testing.expectf(t, calls_to(body, .String_Index_Of) == 2, "%s", result.text)
	for export in ([?]abi.Runtime_Proc{.Number_To_String, .String_Trim, .Number_Parse_Float}) {
		testing.expectf(t, calls_to(body, export) >= 1, "%v:\n%s", export, result.text)
	}
}

@(test)
string_of_nothing_is_the_empty_string :: proc(t: ^testing.T) {
	result := lower_text(t, "function none(): string {\nreturn String();\n}\nnone();\n")
	body, _ := func_named(result.output, "m1.none")
	testing.expectf(t, len(instructions_of(body, ir.Call_Runtime)) == 0, "%s", result.text)
	returns := instructions_of(body, ir.Return)
	if !testing.expectf(t, len(returns) == 1, "%s", result.text) {
		return
	}
	text, is_constant := body.values[returns[0].value].variant.(ir.Const_String)
	testing.expect(t, is_constant, "String() is no constant")
	testing.expect_value(t, len(result.output.strings[text.text]), 0)
}
