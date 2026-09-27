package check_tests

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

// Object literals and their types.

@(test)
object_fields_are_in_canonical_order :: proc(t: ^testing.T) {
	// Requirements 3.3 makes the layout from the fields in canonical order, by name, so the type
	// prints in that order however the literal was written.
	c := expect_checked(t, `const record = { name: "a", age: 1 };`)

	testing.expect_value(t, declared_text(c, "record"), "{ age: number; name: string }")
}

// Named types.

@(test)
two_interfaces_with_the_same_fields_are_compatible :: proc(t: ^testing.T) {
	// Requirements 3.3: the set of fields determines the layout, so `Point` and `Vec2` share one
	// and fit each other at no cost. This is the task's first done criterion.
	expect_checked(
		t,
		lines(
			`interface Point { x: number; y: number; }`, //
			`interface Vec2 { x: number; y: number; }`,
			`const p: Point = { x: 1, y: 2 };`,
			`const v: Vec2 = p;`,
			`const back: Point = v;`,
		),
	)
}

@(test)
an_unknown_type_name_is_reported :: proc(t: ^testing.T) {
	expect_errors(t, `const p: Missing = 1;`, []Error{{.Cannot_Find_Name, 1, 10}})
}

@(test)
two_interfaces_that_name_each_other_are_compatible_with_their_twins :: proc(t: ^testing.T) {
	// Two rings of types compared field by field would never end, so the comparison answers yes for
	// a pair it is already inside. Without that this test does not finish.
	expect_checked(
		t,
		lines(
			`interface A { b: B | undefined; }`, //
			`interface B { a: A | undefined; }`,
			`interface A2 { b: B2 | undefined; }`,
			`interface B2 { a: A2 | undefined; }`,
			`function take(value: A): void { }`,
			`function make(value: A2): void { take(value); }`,
		),
	)
}

@(test)
a_generic_of_ones_own_is_rejected_at_its_declaration :: proc(t: ^testing.T) {
	// Generics of one's own are v2 (requirements 2.2), so the declaration is reported once and the
	// uses say nothing more. The machinery behind the arguments is the lib file's and still works:
	// the interface types with `number` in force, so the message is the only thing wrong here.
	c := expect_errors(
		t,
		lines(
			`interface Box<T> { value: T; }`, //
			`const held: Box<number> = { value: 1 };`,
		),
		[]Error{{.Generic_Declaration, 1, 15}},
	)

	testing.expect_value(t, declared_text(c, "held"), "Box<number>")
}

// The exact-type rule.

@(test)
an_extra_field_is_reported_with_a_hint :: proc(t: ^testing.T) {
	// Requirements 3.3: an object goes only where the same set of fields is expected. This is the
	// task's second done criterion, and the message names the field rather than printing two shapes.
	text := lines(
		`interface Point { x: number; y: number; }`, //
		`const p: Point = { x: 1, y: 2, z: 3 };`,
	)
	c := expect_errors(t, text, {{.Field_Not_Found, 2, 32}})

	message := rendered(c, 0)
	testing.expectf(
		t,
		strings.contains(message, "`z` is not a field of type `Point`"),
		"the message names the field: %q",
		message,
	)
	testing.expectf(
		t,
		strings.contains(message, "hint: check the spelling"),
		"the message has a hint: %q",
		message,
	)
}

@(test)
a_field_whose_type_does_not_fit_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`interface Point { x: number; y: number; }`, //
			`const p: Point = { x: 1, y: "two" };`,
		),
		[]Error{{.Type_Mismatch, 2, 29}},
	)
}

@(test)
two_object_types_with_different_fields_do_not_fit :: proc(t: ^testing.T) {
	// The rule is about types, not only about literals: a value that already has a type has the
	// layout of that type, and the two layouts differ.
	expect_errors(
		t,
		lines(
			`interface Point { x: number; y: number; }`, //
			`interface Point3 { x: number; y: number; z: number; }`,
			`const big: Point3 = { x: 1, y: 2, z: 3 };`,
			`const small: Point = big;`,
		),
		[]Error{{.Field_Not_Found, 4, 22}},
	)
}

// Optional and readonly.

@(test)
a_value_that_is_not_a_literal_needs_the_same_set_of_fields :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`interface Opts { x: number; y?: number; }`, //
			`const plain = { x: 1 };`,
			`const opts: Opts = plain;`,
		),
		[]Error{{.Missing_Field, 3, 20}},
	)
}

@(test)
an_optional_field_prints_with_its_question_mark :: proc(t: ^testing.T) {
	// The question mark is part of the field set and stays in the type. Only a read of the slot
	// names `undefined`, because requirements 3.4 gives a missing field and a `T | undefined` one
	// representation.
	c := expect_checked(
		t,
		lines(
			`const opts: { x: number; y?: string } = { x: 1 };`, //
			`const read = opts.y;`,
		),
	)

	testing.expect_value(t, declared_text(c, "opts"), "{ x: number; y?: string }")
	testing.expect_value(t, declared_text(c, "read"), "string | undefined")
}

@(test)
readonly_does_not_change_what_a_type_fits :: proc(t: ^testing.T) {
	// TypeScript compares the fields and not who may write them, and so does tsnc: `readonly` says
	// what this name may do, not what the object holds.
	expect_checked(
		t,
		lines(
			`interface Frozen { readonly size: number; }`, //
			`interface Loose { size: number; }`,
			`const f: Frozen = { size: 1 };`,
			`const l: Loose = f;`,
		),
	)
}

// A literal into a union.

@(test)
a_literal_picks_the_member_of_a_union_its_tag_names :: proc(t: ^testing.T) {
	// The members have the same field names, so only the literal the tag is written with tells
	// them apart. Picking by names alone would always land on the first.
	c := expect_checked(
		t,
		lines(
			`interface Add { kind: "add"; left: number; right: number; }`, //
			`interface Sub { kind: "sub"; left: number; right: number; }`,
			`const plus: Add | Sub = { kind: "add", left: 1, right: 2 };`,
			`const minus: Add | Sub = { kind: "sub", left: 1, right: 2 };`,
			`function value(n: Add | Sub): number { return n.left; }`,
			`const answer = value({ kind: "sub", left: 1, right: 2 });`,
			`const echoed = minus;`,
		),
	)

	// The declaration keeps the type it was written with; the literal's own answer is what the
	// write left behind, which a read after it holds.
	testing.expect_value(t, declared_text(c, "echoed"), "Sub")
}

@(test)
a_literal_whose_tag_fits_no_member_is_reported_once :: proc(t: ^testing.T) {
	// No member takes the tag, so the second pass picks by names alone and the value is measured
	// against that one: one mistake, one message.
	expect_errors(
		t,
		lines(
			`interface Add { kind: "add"; left: number; }`, //
			`interface Sub { kind: "sub"; left: number; }`,
			`const times: Add | Sub = { kind: "mul", left: 1 };`,
		),
		[]Error{{.Type_Mismatch, 3, 34}},
	)
}

@(test)
a_tag_written_as_a_name_falls_back_to_the_field_names :: proc(t: ^testing.T) {
	// `{ kind: k }` says nothing before anything is typed, so the choice is the first member the
	// names fit, and the value is measured against it.
	expect_errors(
		t,
		lines(
			`interface Add { kind: "add"; left: number; }`, //
			`interface Sub { kind: "sub"; left: number; }`,
			`const k: "sub" = "sub";`,
			`const times: Add | Sub = { kind: k, left: 1 };`,
		),
		[]Error{{.Type_Mismatch, 4, 34}},
	)
}

// Widenings: an object accepted where a wider object type was expected, which lower turns into one
// layout for both. check_typed asserts on every test that the list is sorted and has no repeats.

@(test)
every_place_a_narrow_object_flows_records_its_widening :: proc(t: ^testing.T) {
	NARROW_AND_WIDE :: "interface A { x: number; }\ninterface B { x: number | string; }\n"
	flows := [?]string {
		"const a: A = { x: 1 };\nconst b: B = a;", // a declarator
		"function show(b: B): void {}\nconst a: A = { x: 1 };\nshow(a);", // an argument
		"function widen(a: A): B { return a; }", // a return
		"const a: A = { x: 1 };\nconst b: B | null = a;", // a member of a union
		"const a: A = { x: 1 };\nconst bs: B[] = [a];", // an element of an array
		"const a: A = { x: 1 };\nlet b: B = { x: \"s\" };\nb = a;", // an assignment
	}
	for flow in flows {
		c := expect_checked(
			t,
			strings.concatenate({NARROW_AND_WIDE, flow}, context.temp_allocator),
		)
		testing.expectf(t, slice.equal(widening_texts(c), []string{"A -> B"}), "%s", flow)
	}
}

@(test)
a_widening_walks_into_the_fields :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`interface Inner { x: number; }`, //
			`interface Wide { x: number | string; }`,
			`interface A { inner: Inner; }`,
			`interface B { inner: Wide; }`,
			`const a: A = { inner: { x: 1 } };`,
			`const b: B = a;`,
		),
	)
	testing.expect(t, slice.equal(widening_texts(c), []string{"A -> B", "Inner -> Wide"}))
}

@(test)
a_widening_of_an_interface_that_names_itself_ends :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`interface Node { next: Node | null; value: number; }`, //
			`interface Link { next: Link | null; value: number; }`,
			`const n: Node = { next: null, value: 1 };`,
			`const l: Link = n;`,
		),
	)
	testing.expect(t, slice.equal(widening_texts(c), []string{"Node -> Link"}))
}

@(test)
one_type_and_arrays_record_nothing :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`interface A { x: number; }`, //
			`const a: A = { x: 1 };`,
			`const same: A = a;`,
			`const xs: number[] = [1, 2];`,
			`const ys: number[] = xs;`,
			`const all: A[] = [a];`,
			`const copy: A[] = all;`,
		),
	)
	testing.expectf(t, len(c.result.widenings) == 0, "%v", widening_texts(c))
}

// A function that flows into another function type is a widening too, which lower turns into one
// signature for both. Its parameters flow the other way, from a caller into the function.
@(test)
a_function_flow_lists_its_pair_and_its_parameters_the_other_way :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`interface Narrow { v: number; }`, //
			`interface Wide { v: number | string; }`,
			`function show(w: Wide): Narrow { return { v: 1 }; }`,
			`const f: (n: Narrow) => Wide = show;`,
		),
	)
	want := []string{"(w: Wide) => Narrow -> (n: Narrow) => Wide", "Narrow -> Wide"}
	testing.expectf(t, slice.equal(widening_texts(c), want), "%v", widening_texts(c))
}

// A callback of the lib is never called through the lib's parameter type, so its own pair is left
// out; the objects inside it still flow.
@(test)
a_lib_callback_lists_no_pair_of_its_own :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`interface Narrow { v: number; }`, //
			`interface Wide { v: number | string; }`,
			`const ns: Narrow[] = [{ v: 1 }];`,
			`ns.forEach((w: Wide) => {});`,
			`console.log([1, 2].map((x, i) => x + i), [3, 1].sort((a, b) => a - b));`,
		),
	)
	testing.expectf(
		t,
		slice.equal(widening_texts(c), []string{"Narrow -> Wide"}),
		"%v",
		widening_texts(c),
	)
}

// push stores the value it is given, so a function pushed into an array of another function type
// flows into that type.
@(test)
a_function_pushed_into_an_array_lists_its_pair :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const fs: ((x: number) => void)[] = [];`, //
			`function show(x: number | string): void {}`,
			`fs.push(show);`,
		),
	)
	want := []string{"(x: number | string) => void -> (x: number) => void"}
	testing.expectf(t, slice.equal(widening_texts(c), want), "%v", widening_texts(c))
}

@(private = "file")
widening_texts :: proc(c: Checked) -> []string {
	texts := make([]string, len(c.result.widenings), context.temp_allocator)
	for widening, i in c.result.widenings {
		source, target := type_text(c, widening.source), type_text(c, widening.target)
		texts[i] = fmt.tprintf("%s -> %s", source, target)
	}
	slice.sort(texts)
	return texts
}
