package parse_tests

import "core:testing"

Subset_Case :: struct {
	text:   string,
	errors: []Error,
	dump:   string,
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
