package check_tests

import "core:testing"

import "../../src/bind"
import "../../src/check"
import "../../src/source"

@(test)
a_name_of_the_lib_module_resolves_from_another_file :: proc(t: ^testing.T) {
	// bind leaves a name its own file does not declare as NO_SYMBOL and says check decides. The lib
	// module is not in this partition, so this also proves a checker reads a file it does not type.
	c := expect_checked(t, `const doubled = NaN * 2;`)

	testing.expect_value(t, declared_text(c, "doubled"), "number")

	ref := use_declaration(c, "NaN")
	testing.expect_value(t, ref.file, LIB)
	testing.expectf(t, ref.symbol != bind.NO_SYMBOL, "NaN resolved to nothing")

	declared := c.program.bound[LIB].symbols[ref.symbol]
	testing.expect_value(t, declared.name.text, "NaN")
}

@(test)
undefined_is_a_name_that_no_file_declares :: proc(t: ^testing.T) {
	// The grammar has a literal for `null` but none for `undefined`, which arrives as an ordinary
	// name, and the lib file does not declare it either.
	c := expect_checked(t, `const missing = undefined;`)
	testing.expect_value(t, declared_text(c, "missing"), "undefined")
}

@(test)
an_unknown_name_is_reported :: proc(t: ^testing.T) {
	expect_errors(t, `const answer = nowhere;`, []Error{{.Cannot_Find_Name, 1, 16}})
}

@(test)
a_variable_with_no_type_and_no_value_is_reported :: proc(t: ^testing.T) {
	// Requirements 5 takes the type of a variable from its initializer, and there is none.
	expect_errors(t, `let empty;`, []Error{{.Missing_Annotation, 1, 5}})
}

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
assigning_to_a_const_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`const fixed = 1;`, //
			`fixed = 2;`,
		),
		[]Error{{.Assign_To_Const, 2, 1}},
	)
}

@(test)
a_use_records_the_declaration_it_names :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const counter = 1;`, //
			`const doubled = counter * 2;`,
		),
	)

	ref := use_declaration(c, "counter")
	testing.expect_value(t, ref.file, MAIN)
	testing.expect_value(t, c.program.bound[MAIN].symbols[ref.symbol].name.text, "counter")
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

	// The lib file was read but not typed, so it has no facts here.
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
