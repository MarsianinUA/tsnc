package parse_tests

import "core:strings"
import "core:testing"

import "../../src/parse"

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

parse_broken_variants :: proc(t: ^testing.T, text: string, loc := #caller_location) {
	tokens, _ := parse.tokenize(text, 0, context.temp_allocator)
	for token in tokens {
		prefix := text[:token.span.end]
		parse_checked(t, prefix, loc)
		without_token := concat(text[:token.span.start], text[token.span.end:])
		parse_checked(t, without_token, loc)
	}
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
