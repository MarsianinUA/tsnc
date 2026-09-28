package lower_tests

import "core:slice"
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
	// The assignment narrows v to a number; v is still stored tagged.
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
	unboxes := instructions_of(body, ir.Unbox)
	testing.expectf(t, len(unboxes) > 0, "%s", result.text)
	for unbox in unboxes {
		guarded := false
		for instruction, id in body.values {
			test := instruction.variant.(ir.Tag_Test) or_continue
			error, fails := fails_unless(result.output, body, ir.Value_ID(id))
			guarded ||=
				test.value == unbox.value &&
				test.tags == {.Number} &&
				fails &&
				error == .Tagged_Holds_Other_Kind
		}
		testing.expectf(t, guarded, "an unbox without a tag test:\n%s", result.text)
	}
}

@(test)
a_narrowed_object_is_checked_by_its_layout_too :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		SHAPES +
		`
		function r(c: Circle | number): number {
			if (typeof c !== "number") {
				return c.radius;
			}
			return 0;
		}
	`,
	)
	body, _ := func_named(result.output, "m1.r")
	loads := instructions_of(body, ir.Field_Load)
	testing.expectf(t, len(loads) > 0, "%s", result.text)
	for load in loads {
		checked := false
		for instruction, id in body.values {
			test := instruction.variant.(ir.Layout_Test) or_continue
			error, fails := fails_unless(result.output, body, ir.Value_ID(id))
			checked ||=
				test.cell == load.cell &&
				body.values[load.cell].type == ir.ref(test.layout) &&
				fails &&
				error == .Tagged_Holds_Other_Kind
		}
		testing.expectf(t, checked, "a field read of an unchecked layout:\n%s", result.text)
	}
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
	testing.expectf(t, len(instructions_of(body, ir.Call_Runtime)) == 0, "%s", result.text)
	testing.expectf(t, tests_tags(body, {.Number}), "%s", result.text)
	// typeof null is "object".
	testing.expectf(t, tests_tags(body, {.Object, .Null}), "%s", result.text)
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
	testing.expectf(t, len(instructions_of(body, ir.Call_Runtime)) == 0, "%s", result.text)
	for leave in instructions_of(body, ir.Return) {
		constant, is_constant := body.values[leave.value].variant.(ir.Const_Bool)
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
	testing.expectf(t, len(instructions_of(body, ir.Call_Runtime)) == 0, "%s", result.text)
	testing.expectf(t, tests_tags(body, {.Number}), "%s", result.text)
	testing.expectf(t, tests_tags(body, {.String}), "%s", result.text)
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
	testing.expectf(t, len(instructions_of(body, ir.Call_Runtime)) == 0, "%s", result.text)
	testing.expectf(t, tests_tags(body, {.Null}), "%s", result.text)
	testing.expectf(t, tests_tags(body, {.Undefined}), "%s", result.text)
}

@(test)
a_nullable_reference_is_truthy_unless_null :: proc(t: ^testing.T) {
	// A reference is always truthy, so `T | null` is true exactly when the pointer is not null. A
	// number may be zero or NaN, and the runtime answers for it.
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
	testing.expectf(t, len(instructions_of(present, ir.Call_Runtime)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(present, ir.Tag_Test)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(present, ir.Null_Test)) > 0, "%s", result.text)
	positive, _ := func_named(result.output, "m1.positive")
	testing.expectf(t, calls_to(positive, .Value_To_Boolean) > 0, "%s", result.text)
}

@(test)
a_reference_or_null_is_one_pointer_slot :: proc(t: ^testing.T) {
	// The node of bench/ts/trees.ts: a header and two pointers, 0 standing for null.
	result := lower_text(
		t,
		`
		interface Tree { left: Tree | null; right: Tree | null; }
		function check(tree: Tree | null): number {
			if (tree === null) { return 0; }
			return 1 + check(tree.left) + check(tree.right);
		}
	`,
	)
	body, _ := func_named(result.output, "m1.check")
	param := body.params[0]
	testing.expectf(t, param.kind == .Ref && param.nullish == .Null, "%s", result.text)
	table := result.output.layouts[param.layout]
	testing.expect_value(t, table.size, 24)
	for field in table.fields {
		testing.expect_value(t, field.kind, abi.Slot_Kind.Ref_Or_Null)
	}
	testing.expectf(t, len(instructions_of(body, ir.Tag_Test)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Box)) == 0, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Unbox)) == 0, "%s", result.text)

	// A narrowed read tests the pointer, which a call may have set to null since the test.
	reads := instructions_of(body, ir.Non_Null)
	testing.expectf(t, len(reads) > 0, "%s", result.text)
	for read in reads {
		guarded := false
		for instruction, id in body.values {
			test := instruction.variant.(ir.Null_Test) or_continue
			error, fails := fails_unless(result.output, body, ir.Value_ID(id))
			guarded ||= test.value == read.value && fails && error == .Tagged_Holds_Other_Kind
		}
		testing.expectf(t, guarded, "a read of an unchecked pointer:\n%s", result.text)
	}
}

@(test)
an_optional_reference_field_is_a_pointer_slot :: proc(t: ^testing.T) {
	// A missing field reads as undefined, which the pointer holds as 0.
	result := lower_text(
		t,
		`
		interface Named { name?: string; }
		function name(n: Named): string {
			return n.name ?? "none";
		}
	`,
	)
	body, _ := func_named(result.output, "m1.name")
	table := result.output.layouts[body.params[0].layout]
	testing.expect_value(t, len(table.fields), 1)
	testing.expect_value(t, table.fields[0].kind, abi.Slot_Kind.Ref_Or_Undefined)
	testing.expect(t, table.fields[0].optional)
	testing.expectf(t, len(instructions_of(body, ir.Tag_Test)) == 0, "%s", result.text)
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
	mixed, _ := func_named(result.output, "m1.mixed")
	testing.expect(t, agreed.result == ir.F64)
	for body in ([2]ir.Func{agreed, mixed}) {
		layouts := make([dynamic]ir.Layout_ID, context.temp_allocator)
		for test in instructions_of(body, ir.Layout_Test) {
			if !slice.contains(layouts[:], test.layout) {
				append(&layouts, test.layout)
			}
		}
		// Members of one layout share one arm, which reads the field once.
		testing.expectf(t, len(layouts) == 1, "%s", result.text)
		testing.expectf(t, len(instructions_of(body, ir.Field_Load)) == 1, "%s", result.text)
	}
	boxes := instructions_of(mixed, ir.Box)
	testing.expectf(t, len(boxes) > 0, "%s", result.text)
	for box in boxes {
		testing.expect_value(t, mixed.values[box.value].type.kind, ir.Type_Kind.Ref)
	}
}
