package parse_tests

import "core:strings"
import "core:testing"

import "../../src/parse"

@(test)
a_missing_part_is_reported_where_it_is_missing :: proc(t: ^testing.T) {
	expect_parse(t, "let x = ;", {{.Expected_Token, 1, 9}}, "(let (x = bad))")
	expect_errors(t, "let x = )", {{.Expected_Token, 1, 9}})
	expect_errors(t, "let class = 1", {{.Expected_Token, 1, 5}})
	expect_errors(t, "function f() {", {{.Expected_Token, 1, 15}})

	parsed := expect_errors(t, "f(1, 2", {{.Expected_Token, 1, 7}})
	testing.expect_value(t, parsed.diagnostics[0].args, [2]string{"`)`", "end of file"})

	parsed = expect_errors(t, "`a${b", {{.Expected_Token, 1, 6}})
	testing.expect_value(t, parsed.diagnostics[0].args, [2]string{"`}`", "end of file"})

	parsed = expect_errors(t, "let x = 1 foo", {{.Expected_Token, 1, 11}})
	testing.expect_value(t, parsed.diagnostics[0].args, [2]string{"`;`", "`foo`"})
}

@(test)
after_an_error_the_parser_finds_the_next_one :: proc(t: ^testing.T) {
	text := lines(
		"let a = ;",
		"let b = 1",
		"f(1, 2;",
		"var c = 3",
		"if (a { b() }",
		"let d = 4",
		"class E {}",
		"let f = a ?? b || c",
		"let g = 5",
	)
	errors := []Error {
		{.Expected_Token, 1, 9},
		{.Expected_Token, 3, 7},
		{.Var_Declaration, 4, 1},
		{.Expected_Token, 5, 7},
		{.Class, 7, 1},
		{.Mixed_Coalesce, 8, 11},
	}
	dump := lines(
		"(let (a = bad))",
		"(let (b = 1))",
		"(expr (call f 1 2))",
		"bad",
		"(if a (block (expr (call b))) _)",
		"(let (d = 4))",
		"bad",
		"(let (f = (?? a (|| b c))))",
		"(let (g = 5))",
	)
	expect_parse(t, text, errors, dump)
}

@(test)
one_syntax_error_per_line_is_reported :: proc(t: ^testing.T) {
	// The errors after the first on a line are its consequences.
	expect_errors(t, "let x = ) + ;", {{.Expected_Token, 1, 9}})
	expect_errors(t, "f(a b c d)", {{.Expected_Token, 1, 5}})
	expect_parse(t, ") let x = 1", {{.Unexpected_Token, 1, 1}}, "(let (x = 1))")
	// A subset rule is never dropped.
	expect_errors(t, "let x = ) + eval", {{.Expected_Token, 1, 9}, {.Eval, 1, 13}})
	expect_errors(
		t,
		"var x = ) + eval",
		{{.Var_Declaration, 1, 1}, {.Expected_Token, 1, 9}, {.Eval, 1, 13}},
	)
}

@(test)
a_broken_statement_ends_where_the_next_one_starts :: proc(t: ^testing.T) {
	expect_parse(
		t,
		"f(a, b\nlet y = 2",
		{{.Expected_Token, 1, 7}},
		lines("(expr (call f a b))", "(let (y = 2))"),
	)
	expect_parse(t, "(x)\n=> 1", {{.Unexpected_Token, 2, 1}}, lines("(expr x)", "(expr 1)"))
	expect_parse(
		t,
		"function f() { let x = (1; return x }\nlet y = 1",
		{{.Expected_Token, 1, 26}},
		lines("(function f [] (block (let (x = 1)) (return x)))", "(let (y = 1))"),
	)
}

@(test)
parse_file_reports_the_tokenizer_errors_too :: proc(t: ^testing.T) {
	expect_parse(
		t,
		"let s = 'a\nvar x",
		{{.Unterminated_String, 1, 9}, {.Var_Declaration, 2, 1}},
		lines(`(let (s = "a"))`, "bad"),
	)
}

// Every prefix of a valid file and every copy of it with one token missing parses to a tree that
// keeps the invariants: no loop runs without progress, no node is lost.
@(test)
broken_variants_of_a_file_keep_the_tree_whole :: proc(t: ^testing.T) {
	text := lines(
		`import { a, type B } from "./a";`,
		`export interface P<T> { readonly x?: T; m<U>(f: (v: T) => U): U[] }`,
		"export type U = | \"a\" | P<number>[] | (() => void);",
		"declare const c: number;",
		"export function f(x: number, ...r: string[]): number {",
		"\tlet s = `a${x + 1}b`, o = { x, y: [1, 2,], z: (v: number) => v * 2 };",
		"\tfor (let i = 0; i < 3; i++) { if (i > 1) break; else continue }",
		"\tfor (const v of r) s += v as string;",
		"\tswitch (x) { case 1: return -x ** 2; default: return x ?? 0 }",
		"\tdo { x-- } while (x >>> 1 >= 0)",
		"\treturn o.z!(x) + (x >>= 1);",
		"}",
		"export { f as g } from \"./f\";",
	)
	expect_errors(t, text, {{.Unary_Before_Power, 9, 30}})
	parse_broken_variants(t, text)

	outside_subset := lines(
		"var v = 1",
		"namespace N { export const x = `a${ {b: [1, ...c]} }` }",
		"@dec class A { m() {} }",
		"try { f?.(x) } catch (e) { throw new Error(\"x\") }",
		"label: for (const [k] of m) { delete o[k]; continue label }",
		"const g = async (x = 1) => await x satisfies T",
		"enum E { A }",
		"import d, * as n from \"./n\"",
		"export default function () { import(\"./m\"); return this }",
	)
	parse_broken_variants(t, outside_subset)
}

// parse_broken_variants parses every token prefix of text and every copy of it with one token
// missing, and checks each tree.
parse_broken_variants :: proc(t: ^testing.T, text: string, loc := #caller_location) {
	tokens, _ := parse.tokenize(text, 0, context.temp_allocator)
	for token in tokens {
		prefix := text[:token.span.end]
		parse_checked(t, prefix, loc)
		without_token := concat(text[:token.span.start], text[token.span.end:])
		parse_checked(t, without_token, loc)
	}
}

// An error reported late, after its line, or a missing token before a new line does not hide the
// error on the next line.
@(test)
an_error_does_not_hide_the_next_line :: proc(t: ^testing.T) {
	expect_errors(
		t,
		"let f = a ?? b || c\nlet g = ;",
		{{.Mixed_Coalesce, 1, 11}, {.Expected_Token, 2, 9}},
	)
	expect_errors(
		t,
		"++f()\nlet g = ;",
		{{.Invalid_Assignment_Target, 1, 3}, {.Expected_Token, 2, 9}},
	)
	expect_errors(
		t,
		"import { a }\nlet x = ;",
		{{.Expected_Token, 1, 13}, {.Expected_Token, 2, 9}},
	)
	expect_errors(t, "const x\nfoo(;", {{.Expected_Token, 1, 8}, {.Expected_Token, 2, 5}})
}

// An unclosed bracket in skipped text is skipped alone: the statements after it still parse.
@(test)
an_unclosed_bracket_does_not_swallow_the_file :: proc(t: ^testing.T) {
	text := lines("let x = 1 foo(", "let y = ;", "var z = 1", "function g() { with (o) {} }")
	errors := []Error {
		{.Expected_Token, 1, 11},
		{.Expected_Token, 2, 9},
		{.Var_Declaration, 3, 1},
		{.With_Statement, 4, 16},
	}
	expect_errors(t, text, errors)

	text = lines("const { a, b", "let y = ;", "var z = 1")
	errors = {
		{.Destructuring, 1, 7},
		{.Expected_Token, 1, 9},
		{.Expected_Token, 2, 9},
		{.Var_Declaration, 3, 1},
	}
	expect_errors(t, text, errors)

	// The `}` of the function closes the function, not the `(`.
	expect_parse(
		t,
		"function f() { g(\n}\nlet y = 1",
		{{.Expected_Token, 1, 18}},
		lines("(function f [] (block (expr (call g bad))))", "(let (y = 1))"),
	)
}

// A value in an object literal may go on over several lines, also after a member that is skipped.
@(test)
a_skipped_object_member_ends_at_its_comma :: proc(t: ^testing.T) {
	expect_parse(
		t,
		lines("const o = {", "  [key]:", "    a && b,", "  c: 1,", "}"),
		{{.Unsupported_Syntax, 2, 3}},
		"(const (o = (object (c 1))))",
	)
	expect_parse(
		t,
		lines("const o = {", "  a:", "    1,", "}"),
		{},
		"(const (o = (object (a 1))))",
	)
}

// A construct that is skipped as a whole ends where it ends, and one mistake gets one error.
@(test)
a_skipped_declaration_ends_at_its_body :: proc(t: ^testing.T) {
	// The missing `{` is the error, not an overload signature.
	expect_parse(t, "function f() return 1", {{.Expected_Token, 1, 14}}, "bad")
	// A `{` in type arguments is an object type, not the class body.
	expect_parse(
		t,
		"class A extends B<{ x: number }> { m() {} }\nlet y = 2",
		{{.Class, 1, 1}},
		lines("bad", "(let (y = 2))"),
	)
	// An unclosed `<` or a missing body does not swallow the next statement.
	expect_parse(t, "class A<T {\n}\nlet y = 2", {{.Class, 1, 1}}, lines("bad", "(let (y = 2))"))
	expect_parse(t, "enum E\nlet y = 2", {{.Enum, 1, 1}}, lines("bad", "(let (y = 2))"))
}

@(test)
an_interface_without_a_body_still_has_one :: proc(t: ^testing.T) {
	expect_parse(
		t,
		"interface I\nlet y = 1",
		{{.Expected_Token, 1, 12}},
		lines("(interface I {})", "(let (y = 1))"),
	)
}

// Tries from a Mark nest: `(x = c ? (x = ...) : 1) : 1` tries an arrow head at every level. A try
// that failed is not repeated, or this would take exponential time.
@(test)
nested_tries_stay_linear :: proc(t: ^testing.T) {
	DEPTH :: 40
	parts: [dynamic]string
	defer delete(parts)
	for _ in 0 ..< DEPTH {
		append(&parts, "c ? (x = ")
	}
	append(&parts, "1")
	for _ in 0 ..< DEPTH {
		append(&parts, ") : 1")
	}
	expect_errors(t, concat(..parts[:]), {})
}

@(test)
a_regular_expression_is_one_error :: proc(t: ^testing.T) {
	// `\d` would also be an unexpected character to tokenize.
	expect_parse(t, "let r = /\x5cd+/", {{.Regular_Expression, 1, 9}}, "(let (r = bad))")
}

// Input that nests past the parser's recursion limit is one error, not a stack overflow: brackets,
// `else if` chains, right-associative chains, prefix operators, functions, types and arrows.
@(test)
deep_nesting_is_an_error_not_a_crash :: proc(t: ^testing.T) {
	repeat :: proc(s: string, count: int) -> string {
		return strings.repeat(s, count, context.temp_allocator)
	}
	N :: 3000
	texts := []string {
		concat(repeat("(", N), "x", repeat(")", N)),
		concat(repeat("[", N), repeat("]", N)),
		concat("x = ", repeat("{a: ", N), "1", repeat("}", N)),
		concat("if (a) {}", repeat(" else if (a) {}", N)),
		concat("a", repeat(" = a", N)),
		concat("a", repeat(" ** a", N)),
		concat(repeat("-", N), "x"),
		concat(repeat("x => ", N), "1"),
		concat(repeat("function f() {", N), repeat("}", N)),
		concat(repeat("{", N), repeat("}", N)),
		concat("type T = ", repeat("Array<", N), "number", repeat(">", N)),
	}
	for text in texts {
		parsed := parse_checked(t, text)
		is_one_error := len(parsed.errors) == 1 && parsed.errors[0].code == .Nesting_Too_Deep
		testing.expectf(t, is_one_error, "%.30q...: errors %v", text, parsed.errors)
	}
	// Ordinary nesting stays well within the limit.
	expect_errors(t, concat(repeat("(", 50), "x", repeat(")", 50)), {})
}

// Long runs of constructs outside the subset recurse through declarations and arrow heads, not
// through brackets. They too end in their errors, not in a stack overflow.
@(test)
long_runs_outside_the_subset_do_not_crash :: proc(t: ^testing.T) {
	N :: 20000
	repeat :: proc(s: string) -> string {
		return strings.repeat(s, N, context.temp_allocator)
	}

	// Decorators are read in a loop: each one is reported, none counts as nesting.
	decorators := make([]Error, N, context.temp_allocator)
	for &e, i in decorators {
		e = {.Decorator, i32(i + 1), 1}
	}
	expect_parse(t, concat(repeat("@a\n"), "let x = 1"), decorators, "(let (x = 1))")

	// Nested namespaces: each level is reported up to the limit, then the nesting is, on the line
	// of the first level past it.
	text := repeat("export namespace A {\n")
	parsed := parse_checked(t, text)
	levels := len(parsed.errors) - 1
	testing.expectf(t, levels > 0, "namespaces: %d errors", len(parsed.errors))
	namespaces := make([]Error, max(levels, 0) + 1, context.temp_allocator)
	for &e, i in namespaces {
		e = {.Namespace, i32(i + 1), 8}
	}
	namespaces[len(namespaces) - 1].code = .Nesting_Too_Deep
	expect_errors_of(t, text, parsed, namespaces)

	// `async async ...` is no arrow at any depth: one expression `async`, then a missing `;`.
	expect_errors(t, concat(repeat("async "), "x => 1"), {{.Expected_Token, 1, 7}})
}
