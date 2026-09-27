package parse_tests

import "core:testing"

@(test)
keyword_types_are_keywords :: proc(t: ^testing.T) {
	keywords := []string {
		"number",
		"string",
		"boolean",
		"null",
		"undefined",
		"void",
		"any",
		"unknown",
		"never",
	}
	for keyword in keywords {
		expect_type(t, keyword, keyword)
	}
}

@(test)
literal_types_keep_their_values :: proc(t: ^testing.T) {
	expect_type(t, `"circle"`, `"circle"`)
	expect_type(t, "42", "42")
	expect_type(t, "-1", "-1")
	expect_type(t, "true", "true")
	expect_type(t, "false", "false")
}

@(test)
type_references_take_a_qualifier_and_arguments :: proc(t: ^testing.T) {
	expect_type(t, "Point", "Point")
	expect_type(t, "m.Point", "m.Point")
	expect_type(t, "Map<string, number[]>", "(Map string (number []))")
	// Two `>` tokens close two lists, also right before `=`.
	expect_type(t, "Array<Array<number>>", "(Array (Array number))")
	expect_tree(
		t,
		"let a: Array<Array<number>>= []",
		"(let (a : (Array (Array number)) = (array)))",
	)
}

@(test)
array_types_nest :: proc(t: ^testing.T) {
	expect_type(t, "T[]", "(T [])")
	expect_type(t, "T[][]", "((T []) [])")
	expect_type(t, "(A | B)[]", "((| A B) [])")
}

@(test)
unions_are_flat :: proc(t: ^testing.T) {
	expect_type(t, "A | B | C", "(| A B C)")
	expect_type(t, "\n\t| \"a\"\n\t| \"b\"", `(| "a" "b")`)
	expect_type(t, "| A", "A")
	// Parentheses keep a union a member of its own.
	expect_type(t, "(A | B) | C", "(| (| A B) C)")
	expect_type(t, "(() => void) | null", "(| (=> [] void) null)")
}

@(test)
function_types_have_parameters_and_a_result :: proc(t: ^testing.T) {
	expect_type(t, "() => void", "(=> [] void)")
	expect_type(t, "(x: T, y?: U, ...z: V[]) => R", "(=> [(x : T) (y? : U) (...z : (V []))] R)")
	expect_type(t, "<U>(x: T) => U", "(=> <U> [(x : T)] U)")
	expect_type(t, "(x) => void", "(=> [x] void)")
	// The result of a function type is a whole union.
	expect_type(t, "() => A | B", "(=> [] (| A B))")
	// A function type in parentheses is told from parameters by what follows the `(`, as tsc tells
	// them apart, not by an arrow after the `)`.
	expect_type(t, "((a: number) => number)", "(=> [(a : number)] number)")
	expect_type(t, "((a) => void)[]", "((=> [a] void) [])")
	// A destructured parameter is read as one, and reported as the v2 construct it is.
	expect_errors(t, "type T = ([a]: T) => void", {{.Destructuring, 1, 11}})
}

@(test)
object_types_have_members :: proc(t: ^testing.T) {
	expect_type(t, "{}", "{}")
	expect_type(
		t,
		"{ readonly x?: number; y: string, \"z\": boolean\n w: T }",
		`{(readonly x? : number) (y : string) (z : boolean) (w : T)}`,
	)
	expect_type(
		t,
		"{ m?<U>(f: (x: T) => U): U[]; n(): void }",
		"{(m? : (=> <U> [(f : (=> [(x : T)] U))] (U []))) (n : (=> [] void))}",
	)
	// Words that are modifiers elsewhere are names here.
	expect_type(
		t,
		"{ readonly: T; get: T; default: T }",
		"{(readonly : T) (get : T) (default : T)}",
	)
}

@(test)
the_lib_file_shape_parses :: proc(t: ^testing.T) {
	text := lines(
		"declare const console: Console;",
		"interface Console { log(...data: any[]): void }",
		"interface Array<T> {",
		"\treadonly length: number;",
		"\tmap<U>(f: (value: T, index: number) => U): U[];",
		"\tpush(...items: T[]): number;",
		"}",
		"declare function parseFloat(s: string): number;",
	)
	array := concat(
		"(interface Array <T> {(readonly length : number) ",
		"(map : (=> <U> [(f : (=> [(value : T) (index : number)] U))] (U []))) ",
		"(push : (=> [(...items : (T []))] number))})",
	)
	expect_tree(
		t,
		text,
		lines(
			"(declare const (console : Console))",
			"(interface Console {(log : (=> [(...data : (any []))] void))})",
			array,
			"(declare function parseFloat [(s : string)] : number _)",
		),
	)
}

@(test)
a_member_without_a_type_is_an_error :: proc(t: ^testing.T) {
	expect_parse(
		t,
		lines("type T = {", "\ta;", "\tm()", "}"),
		{{.Expected_Token, 2, 3}, {.Expected_Token, 3, 5}},
		"(type T = {(a : bad) (m : (=> [] bad))})",
	)
}
