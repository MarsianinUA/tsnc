package check_tests

import "core:strings"
import "core:testing"

@(test)
addition_adds_two_numbers_and_joins_a_string_to_anything :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const sum = 1 + 2;`, //
			`const joined = "a" + "b";`,
			`const labelled = "a" + 1;`,
			`const prefixed = 1 + "a";`,
		),
	)

	testing.expect_value(t, declared_text(c, "sum"), "number")
	testing.expect_value(t, declared_text(c, "joined"), "string")
	testing.expect_value(t, declared_text(c, "labelled"), "string")
	testing.expect_value(t, declared_text(c, "prefixed"), "string")
}

@(test)
addition_of_two_values_that_are_neither_is_reported :: proc(t: ^testing.T) {
	expect_errors(t, `const bad = true + 1;`, []Error{{.Addition_Operands, 1, 13}})
}

@(test)
arithmetic_needs_numbers :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const product = 6 * 7;`, //
			`const rest = 7 % 2;`,
			`const raised = 2 ** 8;`,
		),
	)
	testing.expect_value(t, declared_text(c, "product"), "number")
	testing.expect_value(t, declared_text(c, "rest"), "number")
	testing.expect_value(t, declared_text(c, "raised"), "number")

	expect_errors(t, `const worse = "a" * 2;`, []Error{{.Operand_Not_Number, 1, 15}})
}

@(test)
bitwise_operators_give_a_number :: proc(t: ^testing.T) {
	// Requirements 3.1 puts the conversion to int32 in the semantics, not in the type.
	c := expect_checked(
		t,
		lines(
			`const masked = 6 & 3;`, //
			`const shifted = 1 << 5;`,
			`const flipped = ~0;`,
		),
	)

	testing.expect_value(t, declared_text(c, "masked"), "number")
	testing.expect_value(t, declared_text(c, "shifted"), "number")
	testing.expect_value(t, declared_text(c, "flipped"), "number")
}

@(test)
comparisons_order_two_numbers_or_two_strings :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const smaller = 1 < 2;`, //
			`const earlier = "a" < "b";`,
		),
	)
	testing.expect_value(t, declared_text(c, "smaller"), "boolean")
	testing.expect_value(t, declared_text(c, "earlier"), "boolean")

	expect_errors(t, `const mixed = 1 < "a";`, []Error{{.Comparison_Operands, 1, 15}})
}

@(test)
strict_equality_rejects_two_types_with_no_value_in_common :: proc(t: ^testing.T) {
	// Requirements 3.7 asks nothing of `===` itself, but a comparison whose two sides can never be
	// equal is a mistake and not a test, and tsc reports it as well.
	c := expect_errors(t, `const same = 1 === "a";`, []Error{{.No_Overlap, 1, 14}})
	testing.expectf(
		t,
		strings.contains(rendered(c, 0), "no value in common"),
		"the message does not say the two can never be equal: %q",
		rendered(c, 0),
	)

	ok := expect_checked(t, lines(`let n = 1;`, `const same = n === 2;`))
	testing.expect_value(t, declared_text(ok, "same"), "boolean")
}

@(test)
comparing_different_types_with_double_equals_asks_for_triple_equals :: proc(t: ^testing.T) {
	// Requirements 3.7 and the "Never" list of 2.2: a converting comparison has no honest machine
	// code, so `==` is allowed only where it already means `===`.
	c := expect_errors(t, `const same = 1 == "a";`, []Error{{.Loose_Equality, 1, 14}})
	testing.expectf(
		t,
		strings.contains(rendered(c, 0), "use `===`"),
		"the hint does not offer `===`: %q",
		rendered(c, 0),
	)
}

@(test)
double_equals_between_one_type_is_allowed :: proc(t: ^testing.T) {
	c := expect_checked(t, `const same = 1 == 2;`)
	testing.expect_value(t, declared_text(c, "same"), "boolean")
}

@(test)
the_falsy_side_of_or_is_dropped :: proc(t: ^testing.T) {
	// `name || "none"` is a `string`, not `string | undefined`: the left side survives only where
	// it is truthy. tsc types it the same way, and the differential gate of T4.7 runs tsc --strict.
	c := expect_checked(
		t,
		lines(
			`let name: string | undefined = undefined;`, //
			`const shown: string = name || "none";`,
		),
	)

	testing.expect_value(t, declared_text(c, "shown"), "string")
}

@(test)
and_keeps_the_falsy_side_and_coalesce_keeps_the_rest :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const guard = 0 && "x";`, //
			`let maybe: number | null = null;`,
			`const value: number = maybe ?? 0;`,
		),
	)

	// `a && b` is `a` exactly where `a` is falsy.
	testing.expect_value(t, declared_text(c, "guard"), `0 | "x"`)
	// `??` asks only about null and undefined, so the number survives.
	testing.expect_value(t, declared_text(c, "value"), "number")
}

@(test)
not_takes_anything_and_gives_a_boolean :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const empty = !"a";`, //
			`const negated = -1;`,
		),
	)

	testing.expect_value(t, declared_text(c, "empty"), "boolean")
	// A minus in front of a number is part of the number, as tsc reads it.
	testing.expect_value(t, declared_text(c, "negated"), "-1")
}

@(test)
typeof_gives_the_answers_it_can_produce :: proc(t: ^testing.T) {
	c := expect_checked(t, `const kind = typeof 1;`)
	testing.expect_value(
		t,
		declared_text(c, "kind"),
		`"boolean" | "function" | "number" | "object" | "string" | "undefined"`,
	)
}

@(test)
a_ternary_gives_the_union_of_its_branches :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const pick: number | string = true ? 1 : "a";`, //
			`const both = true ? 1 : 2;`,
		),
	)

	testing.expect_value(t, declared_text(c, "pick"), "number | string")
	testing.expect_value(t, declared_text(c, "both"), `1 | 2`)
}

@(test)
a_template_string_is_a_string :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const count = 2;`, //
			"const text = `there are ${count} of them`;",
		),
	)

	testing.expect_value(t, declared_text(c, "text"), "string")
}

@(test)
update_operators_need_a_number :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`let counter = 0;`, //
			`counter++;`,
			`const after = --counter;`,
		),
	)
	testing.expect_value(t, declared_text(c, "after"), "number")

	expect_errors(
		t,
		lines(
			`let word = "a";`, //
			`word++;`,
		),
		[]Error{{.Operand_Not_Number, 2, 1}},
	)
}

@(test)
assignment_checks_the_declared_type :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`let total = 0;`, //
			`total = 5;`,
			`total += 2;`,
		),
	)

	expect_errors(
		t,
		lines(
			`let total = 0;`, //
			`total = "a";`,
		),
		[]Error{{.Type_Mismatch, 2, 9}},
	)
}

@(test)
compound_assignment_follows_its_operator :: proc(t: ^testing.T) {
	// `total *= "a"` means `total = total * "a"`, so it is the operator that complains first.
	expect_errors(
		t,
		lines(
			`let total = 0;`, //
			`total *= "a";`,
		),
		[]Error{{.Operand_Not_Number, 2, 10}},
	)
}

@(test)
strict_equality_accepts_two_unions_that_share_a_member :: proc(t: ^testing.T) {
	// Neither union fits the other, and `"b"` is still a value both sides can hold, so the
	// comparison is a test and not a mistake.
	expect_checked(
		t,
		lines(
			`function same(a: "a" | "b", b: "b" | "c"): boolean { return a === b; }`, //
			`function wide(a: number | string, b: string | boolean): boolean { return a === b; }`,
		),
	)
}

@(test)
an_assertion_between_two_unions_that_merely_overlap_is_reported :: proc(t: ^testing.T) {
	// `as` may widen a value or narrow a union and nothing in between, which is a narrower rule
	// than having a value in common.
	expect_errors(
		t,
		`function pick(a: "a" | "b"): "b" | "c" { return a as "b" | "c"; }`,
		[]Error{{.Unrelated_Assertion, 1, 49}},
	)
}

@(test)
a_write_to_a_function_declaration_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`function one(): number { return 1; }`, //
			`one = (): number => 2;`,
		),
		[]Error{{.Assign_To_Function, 2, 1}},
	)
}
