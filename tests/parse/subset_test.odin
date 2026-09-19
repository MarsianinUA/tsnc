package parse_tests

import "core:testing"

Subset_Case :: struct {
	text:   string,
	errors: []Error,
	dump:   string,
}

@(test)
never_rules_have_their_codes :: proc(t: ^testing.T) {
	cases := [?]Subset_Case {
		{"var x = 1", {{.Var_Declaration, 1, 1}}, "bad"},
		{
			"for (var i = 0; i < 3; i++) {}",
			{{.Var_Declaration, 1, 6}},
			"(for bad (< i 3) (i ++) (block))",
		},
		{"for (var x of xs) {}", {{.Var_Declaration, 1, 6}}, "bad"},
		{`var x = eval("1")`, {{.Var_Declaration, 1, 1}, {.Eval, 1, 9}}, "bad"},
		{"with (o) { f() }", {{.With_Statement, 1, 1}}, "bad"},
		{"with (o) { var y = 1 }", {{.With_Statement, 1, 1}, {.Var_Declaration, 1, 12}}, "bad"},
		{"namespace N { export const x = 1 }", {{.Namespace, 1, 1}}, "bad"},
		{"module M.N {}", {{.Namespace, 1, 1}}, "bad"},
		{"declare namespace N {}", {{.Namespace, 1, 9}}, "bad"},
		{`declare module "m" {}`, {{.Namespace, 1, 9}}, "bad"},
		{"declare global {}", {{.Namespace, 1, 9}}, "bad"},
		{"@sealed\nclass A {}", {{.Decorator, 1, 1}, {.Class, 2, 1}}, "bad"},
		{"@log() function f() {}", {{.Decorator, 1, 1}}, "(function f [] (block))"},
		{"f(arguments)", {{.Arguments_Object, 1, 3}}, "(expr (call f bad))"},
		{
			"let n = { arguments }",
			{{.Arguments_Object, 1, 11}},
			"(let (n = (object (arguments bad))))",
		},
		{
			"function f(arguments) {}",
			{{.Arguments_Object, 1, 12}},
			"(function f [arguments] (block))",
		},
		{"delete o.x", {{.Delete_Operator, 1, 1}}, "(expr bad)"},
		{`eval("1")`, {{.Eval, 1, 1}}, `(expr (call bad "1"))`},
		{"let eval = 1", {{.Eval, 1, 5}}, "(let (eval = 1))"},
		{`new Function("return 1")`, {{.New_Function, 1, 1}}, "(expr bad)"},
		{"new Function", {{.New_Function, 1, 1}}, "(expr bad)"},
		// Only the names in use are the forbidden ones, not member names and keys.
		{
			"o.arguments; o.eval(); o.delete()",
			{},
			"(expr (. o arguments))\n(expr (call (. o eval)))\n(expr (call (. o delete)))",
		},
		{"x = {arguments: 1, eval: 2}", {}, "(expr (= x (object (arguments 1) (eval 2))))"},
		// A contextual keyword counts only with its name on the same line.
		{"namespace\nN\n{}", {}, "(expr namespace)\n(expr N)\n(block)"},
	}
	for c in cases {
		expect_parse(t, c.text, c.errors, c.dump)
	}
}

// tsnc check lists every construct outside the subset in one pass (requirements 2.3), nested ones
// too.
@(test)
every_never_rule_is_found_in_one_pass :: proc(t: ^testing.T) {
	rules := []string {
		"var a = 1",
		"with (o) {}",
		"namespace N {}",
		"@d function f() {}",
		"f(arguments)",
		"delete o.x",
		`eval("1")`,
		`new Function("")`,
	}
	expected := []Error {
		{.Var_Declaration, 1, 1},
		{.With_Statement, 2, 1},
		{.Namespace, 3, 1},
		{.Decorator, 4, 1},
		{.Arguments_Object, 5, 3},
		{.Delete_Operator, 6, 1},
		{.Eval, 7, 1},
		{.New_Function, 8, 1},
	}
	expect_errors(t, lines(..rules), expected)

	// The same rules inside a function body, one tab in.
	nested := make([]string, len(rules) + 2, context.temp_allocator)
	nested[0] = "function g() {"
	for rule, i in rules {
		nested[i + 1] = concat("\t", rule)
	}
	nested[len(nested) - 1] = "}"
	nested_expected := make([]Error, len(expected), context.temp_allocator)
	for e, i in expected {
		nested_expected[i] = {e.code, e.line + 1, e.column + 1}
	}
	expect_errors(t, lines(..nested), nested_expected)
}

@(test)
constructs_outside_v1_have_family_codes :: proc(t: ^testing.T) {
	cases := [?]Subset_Case {
		{"class A {}", {{.Class, 1, 1}}, "bad"},
		{"abstract class A {}", {{.Class, 1, 1}}, "bad"},
		// A class body is skipped, not parsed.
		{"export class A extends B { m() { var x } }", {{.Class, 1, 8}}, "bad"},
		{"new Map()", {{.New_Expression, 1, 1}}, "(expr bad)"},
		{
			"try { f() } catch (e) { var x = 1 } finally {}",
			{{.Exception, 1, 1}, {.Var_Declaration, 1, 25}},
			"bad",
		},
		{`throw new Error("x")`, {{.Exception, 1, 1}, {.New_Expression, 1, 7}}, "bad"},
		{"async function f() { await g() }", {{.Async, 1, 1}, {.Async, 1, 22}}, "bad"},
		{"for await (const x of xs) {}", {{.Async, 1, 5}}, "bad"},
		{"enum E { A, B }", {{.Enum, 1, 1}}, "bad"},
		{"const enum E { A }", {{.Enum, 1, 1}}, "bad"},
		{"const {a, b} = o", {{.Destructuring, 1, 7}}, "(const (_ = o))"},
		{"function f([a]: T) {}", {{.Destructuring, 1, 12}}, "(function f [(_ : T)] (block))"},
		{"for (const [k, v] of m) {}", {{.Destructuring, 1, 12}}, "(for-of (const _) m (block))"},
		{"f(...xs)", {{.Spread, 1, 3}}, "(expr (call f bad))"},
		{"a?.b()", {{.Optional_Chaining, 1, 2}}, "(expr bad)"},
		{"export default 1", {{.Default_Export, 1, 8}}, "bad"},
		{"export default function () {}", {{.Default_Export, 1, 8}}, "bad"},
		{"export default class {}", {{.Default_Export, 1, 8}, {.Class, 1, 16}}, "bad"},
		{`import x from "./m"`, {{.Default_Export, 1, 8}}, "bad"},
		{`import x, { y } from "./m"`, {{.Default_Export, 1, 8}}, "bad"},
		{`import type T from "./m"`, {{.Default_Export, 1, 8}}, "bad"},
		{`import { default as x } from "./m"`, {{.Default_Export, 1, 10}}, `(import {} "./m")`},
		{"export { x as default }", {{.Default_Export, 1, 15}}, "(export {})"},
		{"const f = function () {}", {{.Function_Expression, 1, 11}}, "(const (f = bad))"},
		{"for (const k in o) {}", {{.For_In, 1, 1}}, "bad"},
		{"for (k in o) {}", {{.For_In, 1, 1}}, "bad"},
		{"let r = /ab+c/i", {{.Regular_Expression, 1, 9}}, "(let (r = bad))"},
	}
	for c in cases {
		expect_parse(t, c.text, c.errors, c.dump)
	}
}

@(test)
other_constructs_outside_v1_are_named :: proc(t: ^testing.T) {
	cases := [?]Subset_Case {
		{
			"L: for (;;) { break L }",
			{{.Unsupported_Syntax, 1, 1}, {.Unsupported_Syntax, 1, 21}},
			"(for _ _ _ (block break))",
		},
		{"debugger", {{.Unsupported_Syntax, 1, 1}}, "bad"},
		{"function* g() {}", {{.Unsupported_Syntax, 1, 9}}, "bad"},
		{"function f(x = 1) {}", {{.Unsupported_Syntax, 1, 14}}, "(function f [x] (block))"},
		{"function f(this: T) {}", {{.Unsupported_Syntax, 1, 12}}, "(function f [] (block))"},
		{"function f(): void;", {{.Unsupported_Syntax, 1, 1}}, "bad"},
		{`export * from "./m"`, {{.Unsupported_Syntax, 1, 8}}, "bad"},
		{`import x = require("m")`, {{.Unsupported_Syntax, 1, 8}}, "bad"},
		{
			`import { a } from "./m" with { type: "json" }`,
			{{.Unsupported_Syntax, 1, 25}},
			`(import {a} "./m")`,
		},
		{"for (x of xs) {}", {{.Unsupported_Syntax, 1, 1}}, "bad"},
		{"for (i = 0, j = 1; ; ) {}", {{.Unsupported_Syntax, 1, 11}}, "(for bad _ _ (block))"},
		{"interface A extends B {}", {{.Unsupported_Syntax, 1, 13}}, "(interface A {})"},
	}
	for c in cases {
		expect_parse(t, c.text, c.errors, c.dump)
	}
	// The message names the construct.
	parsed := expect_errors(t, "debugger", {{.Unsupported_Syntax, 1, 1}})
	testing.expect_value(t, parsed.diagnostics[0].args[0], "`debugger` statements")
}

@(test)
review_cases_get_the_right_code :: proc(t: ^testing.T) {
	cases := [?]Subset_Case {
		{"type T = A extends B ? C : D", {{.Unsupported_Syntax, 1, 12}}, "(type T = bad)"},
		{
			"function f(x): asserts x is T {}",
			{{.Unsupported_Syntax, 1, 16}},
			"(function f [x] : bad (block))",
		},
		{"export default async function () {}", {{.Default_Export, 1, 8}, {.Async, 1, 16}}, "bad"},
		{`export { a as "b" }`, {{.Unsupported_Syntax, 1, 15}}, "(export {})"},
		{"({ x = 1 } = o)", {{.Destructuring, 1, 2}, {.Destructuring, 1, 6}}, "(expr bad)"},
		{`import { eval } from "m"`, {{.Eval, 1, 10}}, `(import {eval} "m")`},
		{
			`import { x as arguments } from "m"`,
			{{.Arguments_Object, 1, 15}},
			`(import {(x as arguments)} "m")`,
		},
		// One chain is one construct.
		{"a?.b?.c", {{.Optional_Chaining, 1, 2}}, "(expr bad)"},
	}
	for c in cases {
		expect_parse(t, c.text, c.errors, c.dump)
	}
}
