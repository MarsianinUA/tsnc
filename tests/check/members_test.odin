package check_tests

import "core:testing"

// What the lib file declares, reached the way a program reaches it. These are the members of
// requirements 2.2, and the point of each test is that check finds it without knowing its name.

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
