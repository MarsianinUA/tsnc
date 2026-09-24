package lower_tests

import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/ir"

/*
Widening: a narrow object accepted where a wide object type was expected is the same object after
the flow, as in Node. Both types get one layout, whose slot is Tagged where the two disagree, so the
flow converts nothing, and a read through the narrow type checks what the slot holds.
*/

@(private = "file")
NARROW_AND_WIDE :: "interface Narrow { x: number; }\ninterface Wide { x: number | string; }\n"

@(test)
a_narrow_object_flows_into_a_wide_type_unchanged :: proc(t: ^testing.T) {
	result := lower_text(t, NARROW_AND_WIDE + "const a: Narrow = { x: 1 };\nconst b: Wide = a;\n")
	a, b := result.output.globals[0], result.output.globals[1]
	testing.expect_value(t, a.type, b.type)
	testing.expect_value(
		t,
		result.output.layouts[a.type.layout].fields[0].kind,
		abi.Slot_Kind.Tagged,
	)

	// The value b receives is the one a holds: a load, then a store, and nothing between them. The
	// first store to b is the zero every global starts with.
	init, _ := func_named(result.output, "init$m1")
	last := ir.NO_VALUE
	for store in instructions_of(init, ir.Global_Store) {
		last = store.value if store.global == 1 else last
	}
	_, loaded := init.values[last].variant.(ir.Global_Load)
	testing.expectf(t, loaded, "b takes a converted value:\n%s", result.text)
}

@(test)
a_read_through_the_narrow_type_checks_the_tag :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		NARROW_AND_WIDE +
		"function widen(a: Narrow): Wide { return a; }\n" +
		"function read(a: Narrow): number { return a.x; }\n",
	)
	body, _ := func_named(result.output, "m1.read")
	tests := instructions_of(body, ir.Tag_Test)
	if !testing.expectf(t, len(tests) == 1, "%s", result.text) {
		return
	}
	testing.expect_value(t, tests[0].tags, ir.Tag_Set{.Number})
	testing.expectf(t, len(instructions_of(body, ir.Unbox)) == 1, "%s", result.text)
	fails := instructions_of(body, ir.Fail)
	if testing.expectf(t, len(fails) == 1, "%s", result.text) {
		error := result.output.fail_sites[fails[0].site].error
		testing.expect_value(t, error, abi.Runtime_Error.Field_Holds_Other_Kind)
	}
}

@(test)
a_read_of_an_object_out_of_a_widened_slot_checks_its_layout :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		interface Inner { v: number; }
		interface Holder { item: Inner; }
		interface Loose { item: Inner | null; }
		function loosen(h: Holder): Loose { return h; }
		function read(h: Holder): number { return h.item.v; }
	`,
	)
	body, _ := func_named(result.output, "m1.read")
	checks := instructions_of(body, ir.Layout_Test)
	if !testing.expectf(t, len(checks) == 1, "%s", result.text) {
		return
	}
	// The layout of the item it unboxed, which is not the layout of the holder it read it from.
	unboxed := body.values[checks[0].cell].type
	testing.expect_value(t, checks[0].layout, unboxed.layout)
	testing.expect(t, checks[0].layout != body.params[0].layout, "the check names the holder")
	testing.expectf(t, len(instructions_of(body, ir.Fail)) == 1, "%s", result.text)
}

@(test)
a_write_through_the_narrow_type_boxes_into_the_slot :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		NARROW_AND_WIDE +
		"function widen(a: Narrow): Wide { return a; }\n" +
		"function write(a: Narrow): void { a.x = 2; }\n",
	)
	body, _ := func_named(result.output, "m1.write")
	testing.expectf(t, len(instructions_of(body, ir.Box)) == 1, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Field_Store_Ref)) == 1, "%s", result.text)
	testing.expectf(t, len(instructions_of(body, ir.Field_Store)) == 0, "%s", result.text)
}

@(test)
a_widening_reaches_a_nested_object :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		interface Inner { v: number; }
		interface InnerWide { v: number | boolean; }
		interface Outer { inner: Inner; }
		interface OuterWide { inner: InnerWide; }
		function widen(o: Outer): OuterWide { return o; }
		const inner: Inner = { v: 1 };
	`,
	)
	layout := result.output.layouts[result.output.globals[0].type.layout]
	testing.expect_value(t, layout.fields[0].kind, abi.Slot_Kind.Tagged)
}

@(test)
two_objects_of_one_class_compare_and_assert_as_they_are :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		NARROW_AND_WIDE +
		"const a: Narrow = { x: 1 };\nconst b: Wide = a;\n" +
		"const same = a === b;\nconst back = b as Narrow;\n",
	)
	init, _ := func_named(result.output, "init$m1")
	compares := instructions_of(init, ir.Compare)
	if !testing.expectf(t, len(compares) == 1, "%s", result.text) {
		return
	}
	left, right := init.values[compares[0].left].type, init.values[compares[0].right].type
	testing.expect_value(t, left.kind, ir.Type_Kind.Ref)
	testing.expect_value(t, left, right)
	converted :=
		strings.contains(result.text, "unbox") || strings.contains(result.text, "tag_test")
	testing.expectf(
		t,
		!converted,
		"a conversion between two objects of one class:\n%s",
		result.text,
	)
}
