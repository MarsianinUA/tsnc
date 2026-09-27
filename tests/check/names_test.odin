package check_tests

import "core:testing"

import "../../src/check"
import "../../src/source"

@(test)
a_parameter_with_no_type_is_reported :: proc(t: ^testing.T) {
	// Only an arrow written inside a call takes its parameter types from the signature it goes
	// into. Everywhere else a name with no type is a name nothing can check.
	expect_errors(
		t,
		`function twice(n): number { return 1; }`,
		[]Error{{.Missing_Annotation, 1, 16}},
	)
}

@(test)
a_name_used_above_its_declaration_is_typed_once :: proc(t: ^testing.T) {
	// A function is typed through its symbol, wherever it is first reached, so the mistake in its
	// body is reported once and not once per use.
	expect_errors(
		t,
		lines(
			`const first = broken();`, //
			`const second = broken();`,
			`function broken() { return "a" * 2; }`,
		),
		[]Error{{.Operand_Not_Number, 3, 28}},
	)
}

@(test)
a_mistake_inside_a_rejected_construct_is_still_found :: proc(t: ^testing.T) {
	// The parts of a construct are typed even where the construct itself is refused, so nothing
	// hides inside one. The error type is assignable in both directions, so the refusal itself
	// cascades no further.
	expect_errors(t, `const numbers = [1, "a" * 2];`, []Error{{.Operand_Not_Number, 1, 21}})
	expect_errors(
		t,
		`const p = { __proto__: "a" * 2 };`,
		[]Error{{.Prototype_Access, 1, 13}, {.Operand_Not_Number, 1, 24}},
	)
}

@(test)
the_well_known_types_are_where_the_constants_say :: proc(t: ^testing.T) {
	c := expect_checked(t, `const n = 1;`)

	testing.expect_value(t, check.ERROR, check.Type_ID(0))
	testing.expect_value(t, len(c.result.partition), 1)
	testing.expect_value(t, c.result.partition[0], MAIN)

	_, typed := check.typed_file(c.result, LIB)
	testing.expectf(t, !typed, "the lib file is not in this partition, so it has no Typed_File")
}

@(test)
a_mistake_inside_a_nested_function_is_reported_once :: proc(t: ^testing.T) {
	// The inner function is typed through its own symbol while the body of the outer one is being
	// read, and the walk over the statements finds the answer already there.
	expect_errors(
		t,
		lines(
			`function outer(): number {`, //
			`	function inner() { return "a" * 2; }`,
			`	return inner() ? 1 : 2;`,
			`}`,
		),
		[]Error{{.Operand_Not_Number, 2, 28}},
	)
}

@(test)
a_checker_reports_only_the_files_of_its_partition :: proc(t: ^testing.T) {
	// Every file belongs to exactly one partition, so a mistake in a file this call does not type
	// belongs to the checker that does. That is what makes one partition and any other split give
	// the same diagnostics, which T6.2 compares byte for byte.
	sources := [2]string {
		`const good = 1;`, //
		`const bad: number = "a";`,
	}
	first := [1]source.File_ID{MAIN}
	second := [1]source.File_ID{MAIN + 1}

	one := check_sources(t, sources[:], first[:])
	testing.expectf(t, len(one.errors) == 0, "another file's mistake leaked in: %v", one.errors)

	two := check_sources(t, sources[:], second[:])
	testing.expect_value(t, len(two.errors), 1)
}
