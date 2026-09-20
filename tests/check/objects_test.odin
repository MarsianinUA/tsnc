package check_tests

import "core:strings"
import "core:testing"

// Object literals and their types.

@(test)
an_object_literal_takes_its_type_from_its_properties :: proc(t: ^testing.T) {
	// Requirements 5 works out a variable's type from its initializer. A field can take another
	// value of its kind later, so each one widens, which is what tsc does as well.
	c := expect_checked(t, `const point = { x: 1, y: 2 };`)

	testing.expect_value(t, declared_text(c, "point"), "{ x: number; y: number }")
}

@(test)
object_fields_are_in_canonical_order :: proc(t: ^testing.T) {
	// Requirements 3.3 makes the layout from the fields in canonical order, by name, so the type
	// prints in that order however the literal was written.
	c := expect_checked(t, `const record = { name: "a", age: 1 };`)

	testing.expect_value(t, declared_text(c, "record"), "{ age: number; name: string }")
}

@(test)
an_object_literal_keeps_the_field_type_the_context_asked_for :: proc(t: ^testing.T) {
	// The literal is going into a type that asked for the one value, so the field does not widen.
	c := expect_checked(
		t,
		lines(
			`interface Circle { kind: "circle"; radius: number; }`, //
			`const unit: Circle = { kind: "circle", radius: 1 };`,
		),
	)

	testing.expect_value(t, declared_text(c, "unit"), "Circle")
}

@(test)
objects_nest :: proc(t: ^testing.T) {
	c := expect_checked(t, `const line = { from: { x: 0 }, to: { x: 1 } };`)

	testing.expect_value(t, declared_text(c, "line"), "{ from: { x: number }; to: { x: number } }")
}

@(test)
a_duplicate_field_is_reported :: proc(t: ^testing.T) {
	expect_errors(t, `const twice = { a: 1, a: 2 };`, []Error{{.Duplicate_Field, 1, 23}})
}

// Named types.

@(test)
an_interface_declares_an_object_type :: proc(t: ^testing.T) {
	c := expect_checked(t, `interface Point { x: number; y: number; }`)

	testing.expect_value(t, declared_type_text(c, "Point"), "Point")
}

@(test)
a_type_alias_stands_for_what_it_names :: proc(t: ^testing.T) {
	// An alias is transparent, as it is in TypeScript: it is another spelling of one type, not a
	// type of its own.
	c := expect_checked(
		t,
		lines(
			`type Count = number;`, //
			`type Shape = { size: number };`,
			`const n: Count = 1;`,
			`const s: Shape = { size: 2 };`,
		),
	)

	testing.expect_value(t, declared_text(c, "n"), "number")
	testing.expect_value(t, declared_text(c, "s"), "{ size: number }")
}

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
a_type_alias_that_names_itself_is_reported :: proc(t: ^testing.T) {
	// An alias has nothing to stand for when it stands for itself. An interface may name itself,
	// because its row is reserved before its members are read.
	expect_errors(t, `type Node = { next: Node };`, []Error{{.Circular_Type, 1, 21}})
}

@(test)
an_interface_may_name_itself :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`interface Node { value: number; next: Node | undefined; }`, //
			`const tail: Node = { value: 2, next: undefined };`,
			`const head: Node = { value: 1, next: tail };`,
		),
	)

	testing.expect_value(t, declared_text(c, "head"), "Node")
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

@(test)
the_wrong_number_of_type_arguments_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`interface Point { x: number; }`, //
			`const p: Point<number> = { x: 1 };`,
		),
		[]Error{{.Type_Argument_Count, 2, 10}},
	)
}

// The exact-type rule.

@(test)
an_extra_field_is_reported_with_a_hint :: proc(t: ^testing.T) {
	// Requirements 3.3: an object goes only where the same set of fields is expected. This is the
	// task's second done criterion, and the message names the field rather than printing two shapes.
	c := expect_errors(
		t,
		lines(
			`interface Point { x: number; y: number; }`, //
			`const p: Point = { x: 1, y: 2, z: 3 };`,
		),
		[]Error{{.Field_Not_Found, 2, 32}},
	)

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
a_missing_field_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`interface Point { x: number; y: number; }`, //
			`const p: Point = { x: 1 };`,
		),
		[]Error{{.Missing_Field, 2, 18}},
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
an_object_literal_may_leave_out_an_optional_field :: proc(t: ^testing.T) {
	// A fresh literal is checked against the type it goes into, so it may leave out a field written
	// `y?: T`; T5.7 puts `undefined` in the slot. Two types still need the same set of fields.
	c := expect_checked(
		t,
		lines(
			`interface Opts { x: number; y?: number; }`, //
			`const one: Opts = { x: 1 };`,
			`const both: Opts = { x: 1, y: 2 };`,
		),
	)

	testing.expect_value(t, declared_text(c, "one"), "Opts")
	testing.expect_value(t, declared_text(c, "both"), "Opts")
}

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
writing_to_a_readonly_field_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`interface Frozen { readonly size: number; }`, //
			`const f: Frozen = { size: 1 };`,
			`f.size = 2;`,
		),
		[]Error{{.Assign_To_Readonly, 3, 3}},
	)
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

// Members.

@(test)
reading_a_field_gives_its_type :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const point = { x: 1, label: "a" };`, //
			`const label = point.label;`,
		),
	)

	testing.expect_value(t, declared_text(c, "label"), "string")
}

@(test)
reading_a_field_that_is_not_there_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`interface Point { x: number; }`, //
			`const p: Point = { x: 1 };`,
			`const z = p.z;`,
		),
		[]Error{{.Field_Not_Found, 3, 13}},
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
