package lower_tests

import "core:testing"

import "../../src/abi"
import "../../src/ir"

/*
Unions and `any`: a tagged value becomes static only after a check. A read check narrowed is a tag
test and an unbox, `typeof`, `===` and truthiness read the tag or ask the runtime, and a field of a
union of objects is a dispatch over the layouts its members have.
*/

@(private = "file")
SHAPES :: `
interface Circle { kind: "circle"; radius: number; }
interface Square { kind: "square"; side: number; }
interface Rect { kind: "rect"; width: number; height: number; }
type Shape = Circle | Square | Rect;
`

@(test)
a_narrowed_read_tests_the_tag_and_unboxes :: proc(t: ^testing.T) {
	// The assignment narrows v to a number, and nothing else tests a tag here.
	result := lower_text(
		t,
		`
		function f(): number {
			let v: number | string = 1;
			return v;
		}
	`,
	)
	body, _ := func_named(result.output, "m1.f")
	tests := instructions_of(body, ir.Tag_Test)
	fails := instructions_of(body, ir.Fail)
	if !testing.expectf(t, len(tests) == 1 && len(fails) == 1, "%s", result.text) {
		return
	}
	testing.expect_value(t, tests[0].tags, ir.Tag_Set{.Number})
	testing.expectf(t, len(instructions_of(body, ir.Unbox)) == 1, "%s", result.text)
	error := result.output.fail_sites[fails[0].site].error
	testing.expect_value(t, error, abi.Runtime_Error.Tagged_Holds_Other_Kind)
}

@(test)
a_narrowed_object_is_checked_by_its_layout_too :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		SHAPES +
		`
		function r(c: Circle | null): number {
			if (c !== null) {
				return c.radius;
			}
			return 0;
		}
	`,
	)
	body, _ := func_named(result.output, "m1.r")
	checks := instructions_of(body, ir.Layout_Test)
	if !testing.expectf(t, len(checks) == 1, "%s", result.text) {
		return
	}
	// The layout of the unboxed reference, which the field load then reads.
	testing.expect_value(t, body.values[checks[0].cell].type, ir.ref(checks[0].layout))
}

@(test)
typeof_compared_with_a_word_is_a_tag_test :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function f(v: number | string | null): number {
			if (typeof v === "number") { return 1; }
			if (typeof v !== "object") { return 2; }
			return 3;
		}
	`,
	)
	body, _ := func_named(result.output, "m1.f")
	testing.expectf(t, calls_to(body, .Value_Typeof) == 0, "%s", result.text)
	tests := instructions_of(body, ir.Tag_Test)
	if !testing.expectf(t, len(tests) == 2, "%s", result.text) {
		return
	}
	testing.expect_value(t, tests[0].tags, ir.Tag_Set{.Number})
	// typeof null is "object".
	testing.expect_value(t, tests[1].tags, ir.Tag_Set{.Object, .Null})
}

@(test)
typeof_of_a_static_value_is_a_constant :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function f(n: number): boolean {
			return typeof n === "string";
		}
	`,
	)
	body, _ := func_named(result.output, "m1.f")
	testing.expectf(t, len(instructions_of(body, ir.Tag_Test)) == 0, "%s", result.text)
	returns := instructions_of(body, ir.Return)
	if testing.expectf(t, len(returns) == 1, "%s", result.text) {
		constant, is_constant := body.values[returns[0].value].variant.(ir.Const_Bool)
		testing.expectf(t, is_constant && !constant.value, "%s", result.text)
	}
}

@(test)
a_switch_over_typeof_tests_the_tag_of_each_case :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function f(v: number | string | boolean): number {
			switch (typeof v) {
				case "number":
					return 1;
				case "string":
					return 2;
				default:
					return 3;
			}
		}
	`,
	)
	body, _ := func_named(result.output, "m1.f")
	testing.expectf(t, calls_to(body, .Value_Typeof) == 0, "%s", result.text)
	tests := instructions_of(body, ir.Tag_Test)
	if testing.expectf(t, len(tests) == 2, "%s", result.text) {
		testing.expect_value(t, tests[0].tags, ir.Tag_Set{.Number})
		testing.expect_value(t, tests[1].tags, ir.Tag_Set{.String})
	}
}

@(test)
a_comparison_with_null_or_undefined_is_a_tag_test :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function f(v: number | null | undefined): number {
			if (v === null) { return 1; }
			if (v !== undefined) { return 2; }
			return 3;
		}
	`,
	)
	body, _ := func_named(result.output, "m1.f")
	testing.expectf(t, calls_to(body, .Value_Equal) == 0, "%s", result.text)
	tests := instructions_of(body, ir.Tag_Test)
	if testing.expectf(t, len(tests) == 2, "%s", result.text) {
		testing.expect_value(t, tests[0].tags, ir.Tag_Set{.Null})
		testing.expect_value(t, tests[1].tags, ir.Tag_Set{.Undefined})
	}
}

@(test)
a_nullable_reference_is_truthy_by_its_tag_alone :: proc(t: ^testing.T) {
	// A reference is always truthy, so `T | null` is true exactly when it is not nullish. A number
	// may be zero or NaN, and the runtime answers for it.
	result := lower_text(
		t,
		SHAPES +
		`
		function present(c: Circle | null): boolean {
			return !c;
		}
		function positive(n: number | undefined): boolean {
			if (n) { return true; }
			return false;
		}
	`,
	)
	present, _ := func_named(result.output, "m1.present")
	testing.expectf(t, calls_to(present, .Value_To_Boolean) == 0, "%s", result.text)
	tests := instructions_of(present, ir.Tag_Test)
	if testing.expectf(t, len(tests) == 1, "%s", result.text) {
		testing.expect_value(t, tests[0].tags, ir.Tag_Set{.Undefined, .Null})
	}
	positive, _ := func_named(result.output, "m1.positive")
	testing.expectf(t, calls_to(positive, .Value_To_Boolean) == 1, "%s", result.text)
}

@(test)
members_of_one_layout_share_one_arm :: proc(t: ^testing.T) {
	// A and B have one shape, so one layout test serves both; they agree on v, which is read as a
	// number. P and Q have one shape too, and there the members disagree on v, which is read as a
	// reference and boxed: the box of an object is an object whatever its layout.
	result := lower_text(
		t,
		`
		interface A { kind: "a"; v: number; }
		interface B { kind: "b"; v: number; }
		function agreed(u: A | B): number {
			return u.v;
		}
		interface X { x: number; }
		interface Y { y: number; }
		interface P { kind: "p"; v: X; }
		interface Q { kind: "q"; v: Y; }
		function mixed(u: P | Q): X | Y {
			return u.v;
		}
	`,
	)
	agreed, _ := func_named(result.output, "m1.agreed")
	testing.expectf(t, len(instructions_of(agreed, ir.Layout_Test)) == 1, "%s", result.text)
	testing.expect(t, agreed.result == ir.F64)

	mixed, _ := func_named(result.output, "m1.mixed")
	testing.expectf(t, len(instructions_of(mixed, ir.Layout_Test)) == 1, "%s", result.text)
	loads := instructions_of(mixed, ir.Field_Load)
	boxes := instructions_of(mixed, ir.Box)
	if testing.expectf(t, len(loads) == 1 && len(boxes) == 1, "%s", result.text) {
		testing.expect_value(t, mixed.values[boxes[0].value].type.kind, ir.Type_Kind.Ref)
	}
}

@(test)
an_optional_field_of_a_union_reads_as_a_tagged_value :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		interface A { a: number; label?: string; }
		interface B { b: string; label?: string; }
		function label(u: A | B): string {
			return u.label ?? "none";
		}
	`,
	)
	body, _ := func_named(result.output, "m1.label")
	testing.expectf(t, len(instructions_of(body, ir.Layout_Test)) == 2, "%s", result.text)
	loads := 0
	for instruction in body.values {
		if _, is_load := instruction.variant.(ir.Field_Load); is_load {
			testing.expect_value(t, instruction.type, ir.TAGGED)
			loads += 1
		}
	}
	testing.expectf(t, loads == 2, "%s", result.text)
}

@(test)
the_length_of_a_string_or_an_array_reads_either :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function size(v: string | number[]): number {
			return v.length;
		}
	`,
	)
	body, _ := func_named(result.output, "m1.size")
	tests := instructions_of(body, ir.Tag_Test)
	if testing.expectf(t, len(tests) == 2, "%s", result.text) {
		testing.expect_value(t, tests[0].tags, ir.Tag_Set{.String})
		testing.expect_value(t, tests[1].tags, ir.Tag_Set{.Object})
	}
	testing.expectf(t, len(instructions_of(body, ir.Layout_Test)) == 1, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Length)) == 2, "%s", result.text)
}

@(test)
a_compound_assignment_reads_the_narrowed_value :: proc(t: ^testing.T) {
	// v is a number inside the test: it is unboxed, added to, and boxed back into its binding. A
	// field of a union is read through one dispatch and written through another.
	result := lower_text(
		t,
		`
		function add(v: number | string): number | string {
			if (typeof v === "number") {
				v += 1;
			}
			return v;
		}
		interface A { kind: "a"; x: number; }
		interface B { kind: "b"; x: number; y: number; }
		function bump(u: A | B): void {
			u.x += 1;
		}
	`,
	)
	add, _ := func_named(result.output, "m1.add")
	testing.expectf(t, len(instructions_of(add, ir.Unbox)) == 1, "%s", result.text)
	testing.expectf(t, len(instructions_of(add, ir.Box)) == 1, "%s", result.text)

	bump, _ := func_named(result.output, "m1.bump")
	testing.expectf(t, len(instructions_of(bump, ir.Layout_Test)) == 4, "%s", result.text)
	stores := instructions_of(bump, ir.Field_Store)
	testing.expectf(t, len(stores) == 2, "%s", result.text)
}
