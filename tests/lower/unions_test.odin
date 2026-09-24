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
typeof_as_a_value_asks_the_runtime :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function word(v: number | string): string {
			return typeof v;
		}
	`,
	)
	body, _ := func_named(result.output, "m1.word")
	testing.expectf(t, calls_to(body, .Value_Typeof) == 1, "%s", result.text)
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
any_other_comparison_with_a_tagged_side_asks_the_runtime :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function same(a: number | string, b: number): boolean {
			return a === b;
		}
	`,
	)
	body, _ := func_named(result.output, "m1.same")
	testing.expectf(t, calls_to(body, .Value_Equal) == 1, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Box)) == 1, "%s", result.text)
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
a_non_null_assertion_fails_on_null_and_undefined :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		SHAPES + `
		function r(c: Circle | undefined): number {
			return c!.radius;
		}
	`,
	)
	body, _ := func_named(result.output, "m1.r")
	tests := instructions_of(body, ir.Tag_Test)
	fails := instructions_of(body, ir.Fail)
	if !testing.expectf(t, len(tests) == 2 && len(fails) == 2, "%s", result.text) {
		return
	}
	testing.expect_value(t, tests[0].tags, ir.Tag_Set{.Undefined, .Null})
	error := result.output.fail_sites[fails[0].site].error
	testing.expect_value(t, error, abi.Runtime_Error.Non_Null_Assertion)
	testing.expect_value(t, tests[1].tags, ir.Tag_Set{.Object})
	testing.expectf(t, len(instructions_of(body, ir.Layout_Test)) == 1, "%s", result.text)
}

@(test)
as_to_a_member_of_a_union_checks_the_tag :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function n(v: number | string): number {
			return v as number;
		}
	`,
	)
	body, _ := func_named(result.output, "m1.n")
	fails := instructions_of(body, ir.Fail)
	if testing.expectf(t, len(fails) == 1, "%s", result.text) {
		error := result.output.fail_sites[fails[0].site].error
		testing.expect_value(t, error, abi.Runtime_Error.Type_Assertion)
	}
	testing.expectf(t, len(instructions_of(body, ir.Unbox)) == 1, "%s", result.text)
}

@(test)
as_to_a_narrower_union_tests_membership :: proc(t: ^testing.T) {
	// A tag for the number, the tag and the layout for the circle, and the value stays tagged.
	result := lower_text(
		t,
		SHAPES +
		`
		function pick(v: number | string | Circle): number | Circle {
			return v as number | Circle;
		}
	`,
	)
	body, _ := func_named(result.output, "m1.pick")
	tests := instructions_of(body, ir.Tag_Test)
	if !testing.expectf(t, len(tests) == 2, "%s", result.text) {
		return
	}
	testing.expect_value(t, tests[0].tags, ir.Tag_Set{.Number})
	testing.expect_value(t, tests[1].tags, ir.Tag_Set{.Object})
	testing.expectf(t, len(instructions_of(body, ir.Layout_Test)) == 1, "%s", result.text)
	fails := instructions_of(body, ir.Fail)
	if testing.expectf(t, len(fails) == 1, "%s", result.text) {
		error := result.output.fail_sites[fails[0].site].error
		testing.expect_value(t, error, abi.Runtime_Error.Type_Assertion)
	}
	testing.expect(t, body.result == ir.TAGGED)
}

@(test)
any_never_becomes_a_function :: proc(t: ^testing.T) {
	// Only the tag of a closure out of `any` could be checked, never its signature. The flow is
	// refused where it happens: an `as`, a declarator, and a union that holds a function.
	result := expect_later(
		t,
		`type F = (x: number) => number;
function f(a: any, u: unknown): void {
const g = a as F;
let h: F | undefined = a;
const k = u as F;
}
`,
		{{.Any_Operation, 3, 11}, {.Any_Operation, 4, 5}, {.Any_Operation, 5, 11}},
	)
	for construct in result.constructs {
		testing.expect_value(t, construct, "become a function")
	}
}

@(test)
a_field_of_a_union_dispatches_over_each_layout :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		SHAPES + `
		function kind(s: Shape): string {
			return s.kind;
		}
	`,
	)
	body, _ := func_named(result.output, "m1.kind")
	tests := instructions_of(body, ir.Tag_Test)
	if testing.expectf(t, len(tests) == 1, "%s", result.text) {
		testing.expect_value(t, tests[0].tags, ir.Tag_Set{.Object})
	}
	checks := instructions_of(body, ir.Layout_Test)
	loads := instructions_of(body, ir.Field_Load)
	testing.expectf(t, len(checks) == 3 && len(loads) == 3, "%s", result.text)
	testing.expect(t, body.result == ir.STR)
	fails := instructions_of(body, ir.Fail)
	if testing.expectf(t, len(fails) == 1, "%s", result.text) {
		error := result.output.fail_sites[fails[0].site].error
		testing.expect_value(t, error, abi.Runtime_Error.Tagged_Holds_Other_Kind)
	}
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
plus_with_an_object_asks_for_its_primitive_first :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function show(p: { x: number }, v: number | string): string {
			return "p=" + p + v;
		}
	`,
	)
	body, _ := func_named(result.output, "m1.show")
	testing.expectf(t, calls_to(body, .Value_To_Primitive_String) == 2, "%s", result.text)
	testing.expectf(t, calls_to(body, .Value_To_String) == 0, "%s", result.text)
}

@(test)
a_short_circuit_unboxes_the_side_it_keeps_on_that_edge :: proc(t: ^testing.T) {
	// `s ?? "none"` and `s || "none"` are strings, and s is one exactly where it is kept: the unbox
	// has a block of its own, and the phi takes it from there.
	result := lower_text(
		t,
		`
		function coalesce(s: string | undefined): string {
			return s ?? "none";
		}
		function either(s: string | undefined): string {
			return s || "none";
		}
	`,
	)
	for name in ([?]string{"m1.coalesce", "m1.either"}) {
		body, _ := func_named(result.output, name)
		unboxes := 0
		for instruction, id in body.values {
			phi, is_phi := instruction.variant.(ir.Phi)
			if !is_phi || instruction.type != ir.STR {
				continue
			}
			for edge in phi.incoming {
				if _, is_unbox := body.values[edge.value].variant.(ir.Unbox); !is_unbox {
					continue
				}
				unboxes += 1
				testing.expectf(
					t,
					block_of(body, edge.value) == edge.block,
					"%s: the unbox of %%%d is not the edge of its phi\n%s",
					name,
					id,
					result.text,
				)
			}
		}
		testing.expectf(t, unboxes == 1, "%s:\n%s", name, result.text)
	}
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

@(test)
console_log_of_a_narrowed_read_does_not_unbox :: proc(t: ^testing.T) {
	// The runtime takes the tagged value as it is, so there is nothing to check.
	result := lower_text(
		t,
		`
		function show(v: number | string): void {
			if (typeof v === "number") {
				console.log(v);
			}
		}
	`,
	)
	body, _ := func_named(result.output, "m1.show")
	testing.expectf(t, len(instructions_of(body, ir.Unbox)) == 0, "%s", result.text)
}

@(test)
a_binding_of_type_never_holds_nothing :: proc(t: ^testing.T) {
	// The idiom that makes a switch exhaustive: s is `never` in the default, and the binding takes
	// no value a join would have to reconcile.
	result := lower_text(
		t,
		SHAPES +
		`
		function area(s: Shape): number {
			switch (s.kind) {
				case "circle":
					return s.radius;
				case "square":
					return s.side;
				case "rect":
					return s.width * s.height;
				default: {
					const unreachable: never = s;
					return unreachable;
				}
			}
		}
	`,
	)
	_, found := func_named(result.output, "m1.area")
	testing.expect(t, found)
}

@(test)
an_optional_number_argument_left_undefined_takes_the_stand_in :: proc(t: ^testing.T) {
	// slice(0, undefined) is slice(0), whose end the runtime takes as +Infinity (abi.MISSING_END).
	result := lower_text(
		t,
		`
		function cut(s: string, end?: number): string {
			return s.slice(0, end);
		}
	`,
	)
	body, _ := func_named(result.output, "m1.cut")
	tests := instructions_of(body, ir.Tag_Test)
	if testing.expectf(t, len(tests) == 2, "%s", result.text) {
		testing.expect_value(t, tests[0].tags, ir.Tag_Set{.Undefined})
	}
	found := false
	for instruction in body.values {
		if constant, is_constant := instruction.variant.(ir.Const_Number); is_constant {
			found ||= constant.value == abi.MISSING_END
		}
	}
	testing.expectf(t, found, "%s", result.text)
}

// block_of answers the block an instruction stands in.
@(private = "file")
block_of :: proc(body: ir.Func, value: ir.Value_ID) -> ir.Block_ID {
	for block, id in body.blocks {
		if slice.contains(block.instructions, value) {
			return ir.Block_ID(id)
		}
	}
	return ir.NO_BLOCK
}
