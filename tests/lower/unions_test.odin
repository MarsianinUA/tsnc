package lower_tests

import "core:slice"
import "core:testing"

import "../../src/abi"
import "../../src/ir"
import "../harness"

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
	body := harness.func_named(t, result.output, "m1.f")
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
	body := harness.func_named(t, result.output, "m1.r")
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
	body := harness.func_named(t, result.output, "m1.f")
	testing.expectf(t, len(instructions_of(body, ir.Call_Runtime)) == 0, "%s", result.text)
	testing.expectf(t, tests_tags(body, {.Number}), "%s", result.text)
	// typeof null is "object".
	testing.expectf(t, tests_tags(body, {.Object, .Null}), "%s", result.text)
}

@(test)
a_nullable_string_takes_no_box_for_typeof_or_equality :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function kind(s: string | undefined): string {
			return typeof s;
		}
		function same(a: string | null, b: string | undefined): boolean {
			return a === b;
		}
	`,
	)
	for name in ([2]string{"m1.kind", "m1.same"}) {
		body := harness.func_named(t, result.output, name)
		testing.expectf(t, len(instructions_of(body, ir.Box)) == 0, "%s", result.text)
		testing.expectf(t, calls_to(body, .Value_Typeof) == 0, "%s", result.text)
		testing.expectf(t, calls_to(body, .Value_Equal) == 0, "%s", result.text)
	}
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
	body := harness.func_named(t, result.output, "m1.f")
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
	body := harness.func_named(t, result.output, "m1.f")
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
	body := harness.func_named(t, result.output, "m1.f")
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
		function named(s: string | null): boolean {
			return !s;
		}
	`,
	)
	present := harness.func_named(t, result.output, "m1.present")
	named := harness.func_named(t, result.output, "m1.named")
	for body in ([2]ir.Func{present, named}) {
		testing.expectf(t, len(instructions_of(body, ir.Call_Runtime)) == 0, "%s", result.text)
		testing.expectf(t, len(instructions_of(body, ir.Tag_Test)) == 0, "%s", result.text)
		testing.expectf(t, len(instructions_of(body, ir.Box)) == 0, "%s", result.text)
		testing.expectf(t, len(instructions_of(body, ir.Null_Test)) > 0, "%s", result.text)
	}
	// An empty string is falsy.
	testing.expectf(t, len(instructions_of(named, ir.Length)) > 0, "%s", result.text)
	positive := harness.func_named(t, result.output, "m1.positive")
	testing.expectf(t, calls_to(positive, .Value_To_Boolean) > 0, "%s", result.text)
}

@(test)
a_tagged_name_declared_as_references_is_truthy_unless_nullish :: proc(t: ^testing.T) {
	// The declaration of v holds only references and nullish values, so one tag test answers. A
	// field is no name, and its read goes to the runtime whatever check narrowed it to.
	result := lower_text(
		t,
		SHAPES +
		`
		function either(v: Circle | Square | null): boolean {
			return !v;
		}
		interface Holder { v: Circle | Square | null; }
		function held(h: Holder): boolean {
			return !h.v;
		}
	`,
	)
	either := harness.func_named(t, result.output, "m1.either")
	testing.expectf(t, len(instructions_of(either, ir.Call_Runtime)) == 0, "%s", result.text)
	testing.expectf(t, tests_tags(either, {.Undefined, .Null}), "%s", result.text)
	held := harness.func_named(t, result.output, "m1.held")
	testing.expectf(t, calls_to(held, .Value_To_Boolean) > 0, "%s", result.text)
}

@(test)
a_reference_or_null_is_one_pointer_slot :: proc(t: ^testing.T) {
	// The node of bench/ts/trees/main.ts: a header and two pointers, 0 standing for null.
	result := lower_text(
		t,
		`
		interface Tree { left: Tree | null; right: Tree | null; }
		function check(tree: Tree | null): number {
			if (tree === null) { return 0; }
			return 1 + check(tree.left) + check(tree.right);
		}
		function same(a: Tree | null, b: Tree | null): boolean {
			return a === b;
		}
	`,
	)
	body := harness.func_named(t, result.output, "m1.check")
	param := body.params[0]
	testing.expectf(t, param.kind == .Ref && param.nullish == .Null, "%s", result.text)
	table := result.output.layouts[param.layout]
	testing.expect_value(t, table.size, 24)
	for field in table.fields {
		testing.expect_value(t, field.kind, abi.Slot_Kind.Ref_Or_Null)
	}
	same := harness.func_named(t, result.output, "m1.same")
	testing.expectf(t, len(instructions_of(same, ir.Compare)) > 0, "%s", result.text)
	for function in ([2]ir.Func{body, same}) {
		testing.expectf(t, len(instructions_of(function, ir.Tag_Test)) == 0, "%s", result.text)
		testing.expectf(t, len(instructions_of(function, ir.Box)) == 0, "%s", result.text)
		testing.expectf(t, len(instructions_of(function, ir.Unbox)) == 0, "%s", result.text)
		testing.expectf(t, len(instructions_of(function, ir.Call_Runtime)) == 0, "%s", result.text)
	}
}

@(test)
a_pointer_read_narrowed_before_a_call_is_tested_again :: proc(t: ^testing.T) {
	// reset may have set root to null since the test that narrowed it.
	result := lower_text(
		t,
		`
		interface Tree { left: Tree | null; }
		let root: Tree | null = { left: null };
		function reset(): void { root = null; }
		function depth(): number {
			if (root === null) { return 0; }
			reset();
			return root.left === null ? 1 : 2;
		}
		depth();
	`,
	)
	body := harness.func_named(t, result.output, "m1.depth")
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
	body := harness.func_named(t, result.output, "m1.name")
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
	agreed := harness.func_named(t, result.output, "m1.agreed")
	mixed := harness.func_named(t, result.output, "m1.mixed")
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
