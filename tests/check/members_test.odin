package check_tests

import "core:testing"

// What the lib file declares, reached the way a program reaches it. These are the members of
// requirements 2.2, and the point of each test is that check finds it without knowing its name.

@(test)
a_string_has_the_members_the_lib_file_declares :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const word = "hello";`, //
			`const size = word.length;`,
			`const part = word.slice(1);`,
			`const code = word.charCodeAt(0);`,
			`const parts = word.split(",");`,
			`const found = word.includes("ell");`,
		),
	)

	testing.expect_value(t, declared_text(c, "size"), "number")
	testing.expect_value(t, declared_text(c, "part"), "string")
	testing.expect_value(t, declared_text(c, "code"), "number")
	testing.expect_value(t, declared_text(c, "parts"), "string[]")
	testing.expect_value(t, declared_text(c, "found"), "boolean")
}

@(test)
a_number_has_the_members_the_lib_file_declares :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const count = 3;`, //
			`const text = count.toString();`,
			`const fixed = count.toFixed(2);`,
		),
	)

	testing.expect_value(t, declared_text(c, "text"), "string")
	testing.expect_value(t, declared_text(c, "fixed"), "string")
}

@(test)
math_reads_through_its_interface :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const pi = Math.PI;`, //
			`const root = Math.sqrt(2);`,
			`const largest = Math.max(1, 2, 3);`,
		),
	)

	testing.expect_value(t, declared_text(c, "pi"), "number")
	testing.expect_value(t, declared_text(c, "root"), "number")
	testing.expect_value(t, declared_text(c, "largest"), "number")
}

@(test)
number_the_value_is_its_constructor :: proc(t: ^testing.T) {
	// A name holds one value and one type: the type `Number` is what a number can do, and the value
	// `Number` is a NumberConstructor, as the lib file says.
	c := expect_checked(
		t,
		lines(
			`const parsed = Number.parseFloat("1.5");`, //
			`const whole = Number.isInteger(2);`,
		),
	)

	testing.expect_value(t, declared_text(c, "parsed"), "number")
	testing.expect_value(t, declared_text(c, "whole"), "boolean")
}

@(test)
console_log_takes_any_number_of_arguments :: proc(t: ^testing.T) {
	// `log(...data: any[])` is a rest parameter, so every argument past it is checked against the
	// element type of `any[]`, which takes anything. Requirements 3.9 asks for exactly that.
	expect_checked(
		t,
		lines(
			`console.log();`, //
			`console.log("hello");`,
			`console.log("hello", 1, true, null);`,
			`console.error("bad");`,
		),
	)
}

@(test)
process_reads_through_its_interface :: proc(t: ^testing.T) {
	c := expect_checked(
		t,
		lines(
			`const args = process.argv;`, //
			`const first = args[0];`,
		),
	)

	testing.expect_value(t, declared_text(c, "args"), "string[]")
	testing.expect_value(t, declared_text(c, "first"), "string")
}

@(test)
process_argv_is_readonly :: proc(t: ^testing.T) {
	expect_errors(t, `process.argv = [];`, []Error{{.Assign_To_Readonly, 1, 9}})
}

@(test)
a_misspelled_member_is_reported :: proc(t: ^testing.T) {
	expect_errors(
		t,
		lines(
			`const word = "hello";`, //
			`const size = word.lenght;`,
		),
		[]Error{{.Field_Not_Found, 2, 19}},
	)
}

@(test)
a_member_of_the_wrong_type_is_reported :: proc(t: ^testing.T) {
	// `slice(start?: number, end?: number)` is narrower than tsc's, and a program that uses the
	// wider form gets a compile error, as the lib file's own comment says.
	expect_errors(
		t,
		lines(
			`const word = "hello";`, //
			`const part = word.slice("1");`,
		),
		[]Error{{.Type_Mismatch, 2, 25}},
	)
}

@(test)
an_optional_parameter_of_a_lib_member_may_be_left_out :: proc(t: ^testing.T) {
	expect_checked(
		t,
		lines(
			`const word = "hello";`, //
			`const trimmed = word.trim();`,
			`const part = word.slice(1);`,
			`const middle = word.slice(1, 3);`,
		),
	)
}

@(test)
the_string_function_and_the_string_type_share_a_name :: proc(t: ^testing.T) {
	// `declare function String(value?: any): string` is the value, while `interface String` holds
	// what a string can do. bind keeps the two meanings apart and check asks for the right one.
	c := expect_checked(t, `const text = String(1);`)

	testing.expect_value(t, declared_text(c, "text"), "string")
}
