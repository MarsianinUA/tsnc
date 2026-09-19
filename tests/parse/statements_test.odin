package parse_tests

import "core:slice"
import "core:testing"

import "../../src/ast"

@(test)
variable_declarations_have_declarators :: proc(t: ^testing.T) {
	expect_tree(t, "let a = 1, b: T;", "(let (a = 1) (b : T))")
	expect_tree(t, "const c: number = 1", "(const (c : number = 1))")
	expect_tree(t, "let x", "(let x)")
	expect_tree(t, "export let x = 1", "(export let (x = 1))")
	expect_tree(t, "declare const x: T;", "(declare const (x : T))")
	expect_tree(t, "export declare const x: T", "(export declare const (x : T))")
	expect_errors(t, "const x;", {{.Expected_Token, 1, 8}})
	expect_errors(t, "declare export const x: T", {{.Expected_Token, 1, 9}})
}

@(test)
functions_interfaces_and_type_aliases_are_declarations :: proc(t: ^testing.T) {
	expect_tree(
		t,
		"function f<T>(x: T, y?: number): T { return x }",
		"(function f <T> [(x : T) (y? : number)] : T (block (return x)))",
	)
	expect_tree(t, "export function g() {}", "(export function g [] (block))")
	expect_tree(
		t,
		"declare function h(...xs: number[]): void;",
		"(declare function h [(...xs : (number []))] : void _)",
	)
	expect_tree(
		t,
		"interface P { x: number; y: number }",
		"(interface P {(x : number) (y : number)})",
	)
	expect_tree(
		t,
		"export interface Box<T> { value: T }",
		"(export interface Box <T> {(value : T)})",
	)
	expect_tree(t, "type Shape = Circle | Square;", "(type Shape = (| Circle Square))")
	expect_tree(
		t,
		"export type Pair<A, B> = { a: A; b: B }",
		"(export type Pair <A B> = {(a : A) (b : B)})",
	)
}

@(test)
imports_and_exports_have_every_form :: proc(t: ^testing.T) {
	text := lines(
		`import { a, b as c, type D } from "./m";`,
		`import type { E } from "./e"`,
		`import * as ns from "./ns";`,
		`import type * as types from "./types";`,
		`import "./side";`,
		`export { a, c as d, type E };`,
		`export { x } from "./x";`,
		`export type { E as F } from "./e";`,
		`import { if as when, type, default_ } from "./words";`,
	)
	parsed := parse_checked(t, text)
	expect_errors_of(t, text, parsed, {})
	expected := lines(
		`(import {a (b as c) (type D)} "./m")`,
		`(import type {E} "./e")`,
		`(import * as ns "./ns")`,
		`(import type * as types "./types")`,
		`(import {} "./side")`,
		`(export {a (c as d) (type E)})`,
		`(export {x} "./x")`,
		`(export type {(E as F)} "./e")`,
		`(import {(if as when) type default_} "./words")`,
	)
	got := dump_statements(parsed.tree)
	testing.expectf(t, got == expected, "got\n%s\nwant\n%s", got, expected)

	// Every statement but the export without `from` is a module request.
	statements := parsed.tree.nodes[ast.ROOT].variant.(ast.Module).statements
	requests := slice.concatenate(
		[][]ast.Node_ID{statements[:5], statements[6:]},
		context.temp_allocator,
	)
	testing.expectf(
		t,
		slice.equal(parsed.tree.imports, requests),
		"imports %v",
		parsed.tree.imports,
	)
}

@(test)
control_statements_have_their_parts :: proc(t: ^testing.T) {
	expect_tree(
		t,
		"if (a) b(); else if (c) d(); else {}",
		"(if a (expr (call b)) (if c (expr (call d)) (block)))",
	)
	expect_tree(t, "if (a) {}", "(if a (block) _)")
	expect_tree(
		t,
		"switch (x) { case 1: a(); case 2: case 3: b(); break; default: c() }",
		"(switch x (case 1 (expr (call a))) (case 2) (case 3 (expr (call b)) break) (default (expr (call c))))",
	)
	expect_tree(t, "for (let i = 0; i < n; i++) {}", "(for (let (i = 0)) (< i n) (i ++) (block))")
	expect_tree(t, "for (;;) {}", "(for _ _ _ (block))")
	expect_tree(t, "for (i = 0; ; ) x()", "(for (= i 0) _ _ (expr (call x)))")
	expect_tree(t, "for (; i < 3;) {}", "(for _ (< i 3) _ (block))")
	expect_tree(t, "for (const x of xs) {}", "(for-of (const x) xs (block))")
	expect_tree(t, "for (let x of f()) g(x)", "(for-of (let x) (call f) (expr (call g x)))")
	expect_tree(t, "while (a) a--", "(while a (expr (a --)))")
	expect_tree(t, "do { a() } while (b)", "(do (block (expr (call a))) b)")
	expect_tree(
		t,
		"function f() { while (1) { break; continue } return 1 }",
		"(function f [] (block (while 1 (block break continue)) (return 1)))",
	)
	expect_tree(t, ";", "empty")
	expect_tree(t, "{ let a = 1 }", "(block (let (a = 1)))")
}

@(test)
semicolons_are_inserted_per_ecmascript :: proc(t: ^testing.T) {
	expect_tree(t, "a = 1\nb = 2", lines("(expr (= a 1))", "(expr (= b 2))"))
	expect_tree(t, "{ a } b", lines("(block (expr a))", "(expr b)"))
	expect_tree(t, "a\n++b", lines("(expr a)", "(expr (++ b))"))
	expect_tree(t, "a\n(b)", "(expr (call a b))")
	expect_tree(t, "function f() {\n\treturn\n\t1\n}", "(function f [] (block (return) (expr 1)))")
	expect_tree(t, "let v = x\n!y", lines("(let (v = x))", "(expr (! y))"))
	expect_tree(t, "let v = x\nas(T)", lines("(let (v = x))", "(expr (call as T))"))
	expect_tree(t, "do {} while (c) f()", lines("(do (block) c)", "(expr (call f))"))
	expect_tree(t, "type\nX = 1", lines("(expr type)", "(expr (= X 1))"))
	expect_tree(
		t,
		"let type = 1; type T = number; for (const of of of) {}",
		lines("(let (type = 1))", "(type T = number)", "(for-of (const of) of (block))"),
	)
	expect_tree(
		t,
		"declare(1)\nnamespace = 2\nmodule.exports = x",
		lines(
			"(expr (call declare 1))",
			"(expr (= namespace 2))",
			"(expr (= (. module exports) x))",
		),
	)

	expect_parse(t, "for (const x = 1 of xs) {}", {{.Expected_Token, 1, 18}}, "bad")
	expect_errors(t, "let x = 1 2", {{.Expected_Token, 1, 11}})
	expect_errors(t, "if x {}", {{.Expected_Token, 1, 4}})
	expect_errors(
		t,
		"for (let i = 0\ni < 3\ni++) {}",
		{{.Expected_Token, 1, 15}, {.Expected_Token, 2, 6}},
	)
}

@(test)
a_body_takes_no_declaration :: proc(t: ^testing.T) {
	expect_parse(t, "if (a) let x = 1", {{.Unexpected_Token, 1, 8}}, "(if a (let (x = 1)) _)")
	expect_parse(
		t,
		"while (a) function f() {}",
		{{.Unexpected_Token, 1, 11}},
		"(while a (function f [] (block)))",
	)
	expect_parse(t, "{ import \"./m\" }", {{.Unexpected_Token, 1, 3}}, "(block bad)")
	expect_parse(
		t,
		"function f() { export let x }",
		{{.Unexpected_Token, 1, 16}},
		"(function f [] (block bad))",
	)
}
