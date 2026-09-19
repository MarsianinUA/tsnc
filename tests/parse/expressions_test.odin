package parse_tests

import "core:testing"

@(test)
binary_operators_go_by_precedence :: proc(t: ^testing.T) {
	// One line per level, loosest first: each operator binds looser than the next one.
	expect_expression(t, "a ?? b ?? c", "(?? (?? a b) c)")
	expect_expression(t, "a || b && c", "(|| a (&& b c))")
	expect_expression(t, "a && b | c", "(&& a (| b c))")
	expect_expression(t, "a | b ^ c", "(| a (^ b c))")
	expect_expression(t, "a ^ b & c", "(^ a (& b c))")
	expect_expression(t, "a & b === c", "(& a (=== b c))")
	expect_expression(t, "a == b < c", "(== a (< b c))")
	expect_expression(t, "a < b << c", "(< a (<< b c))")
	expect_expression(t, "a << b + c", "(<< a (+ b c))")
	expect_expression(t, "a + b * c", "(+ a (* b c))")
	expect_expression(t, "a * b ** c", "(* a (** b c))")
	expect_expression(t, "(a + b) * c", "(* (+ a b) c)")
}

@(test)
associativity_follows_ecmascript :: proc(t: ^testing.T) {
	expect_expression(t, "a - b - c", "(- (- a b) c)")
	expect_expression(t, "a ** b ** c", "(** a (** b c))")
	expect_expression(t, "a = b = c", "(= a (= b c))")
	expect_expression(t, "a ? b : c ? d : e", "(? a b (? c d e))")
	expect_expression(t, "a ? b ? c : d : e", "(? a (? b c d) e)")
	expect_expression(t, "a = b ? c : d", "(= a (? b c d))")
}

@(test)
every_binary_operator_has_its_op :: proc(t: ^testing.T) {
	operators := []string {
		"+",
		"-",
		"*",
		"/",
		"%",
		"**",
		"<<",
		">>",
		">>>",
		"&",
		"|",
		"^",
		"<",
		"<=",
		">",
		">=",
		"==",
		"!=",
		"===",
		"!==",
		"&&",
		"||",
		"??",
	}
	for operator in operators {
		expect_expression(t, concat("a ", operator, " b"), concat("(", operator, " a b)"))
	}
}

@(test)
every_assignment_operator_has_its_op :: proc(t: ^testing.T) {
	operators := []string {
		"=",
		"+=",
		"-=",
		"*=",
		"/=",
		"%=",
		"**=",
		"<<=",
		">>=",
		">>>=",
		"&=",
		"|=",
		"^=",
		"&&=",
		"||=",
		"??=",
	}
	for operator in operators {
		expect_expression(t, concat("a ", operator, " b"), concat("(", operator, " a b)"))
	}
	expect_expression(t, "a.b[i] = 1", "(= (index (. a b) i) 1)")
	expect_expression(t, "x! = 1", "(= (x !) 1)")
	expect_expression(t, "(x) = 1", "(= x 1)")
}

@(test)
greater_tokens_join_only_when_they_touch :: proc(t: ^testing.T) {
	expect_expression(t, "a >= b >> c >>> d", "(>= a (>>> (>> b c) d))")
	expect_expression(t, "a > b > c", "(> (> a b) c)")
	expect_errors(t, "a > = b", {{.Expected_Token, 1, 5}})
	expect_errors(t, "a > > b", {{.Expected_Token, 1, 5}})
}

@(test)
unary_and_update_operators_apply_to_their_operand :: proc(t: ^testing.T) {
	expect_expression(t, "-a", "(- a)")
	expect_expression(t, "+a", "(+ a)")
	expect_expression(t, "!a", "(! a)")
	expect_expression(t, "~a", "(~ a)")
	expect_expression(t, "typeof a === \"string\"", `(=== (typeof a) "string")`)
	expect_expression(t, "- -a", "(- (- a))")
	expect_expression(t, "++a", "(++ a)")
	expect_expression(t, "--a.b", "(-- (. a b))")
	expect_expression(t, "a++", "(a ++)")
	expect_expression(t, "a[i]--", "((index a i) --)")
}

@(test)
member_access_calls_and_non_null_chain :: proc(t: ^testing.T) {
	expect_expression(t, "f()", "(call f)")
	expect_expression(t, "f(a, b,)", "(call f a b)")
	expect_expression(t, "f()()", "(call (call f))")
	expect_expression(t, "a.b.c", "(. (. a b) c)")
	expect_expression(t, "a.default.if", "(. (. a default) if)")
	expect_expression(t, "a[i][j]", "(index (index a i) j)")
	expect_expression(t, "a!.b", "(. (a !) b)")
	expect_expression(t, "a.b!.c()", "(call (. ((. a b) !) c))")
	expect_expression(t, "console.log(`${x}`)", `(call (. console log) (template "" x ""))`)
}

@(test)
as_binds_like_a_comparison :: proc(t: ^testing.T) {
	expect_expression(t, "x as T", "(as x T)")
	expect_expression(t, "a + b as T", "(as (+ a b) T)")
	expect_expression(t, "x as T as U", "(as (as x T) U)")
	expect_expression(t, "x as A | B", "(as x (| A B))")
	expect_expression(t, "x as T === y", "(=== (as x T) y)")
}

@(test)
literals_have_their_values :: proc(t: ^testing.T) {
	expect_expression(t, "1.5", "1.5")
	expect_expression(t, "0x10", "16")
	expect_expression(t, "'a\\n'", `"a\n"`)
	expect_expression(t, "true", "true")
	expect_expression(t, "false", "false")
	expect_expression(t, "null", "null")
	expect_expression(t, "undefined", "undefined")
	expect_expression(t, "[]", "(array)")
	expect_expression(t, "[1, [2], 3,]", "(array 1 (array 2) 3)")
	expect_expression(t, "({})", "(object)")
	expect_expression(
		t,
		"({a: 1, \"b\": 2, c, if: 3, d: {e: []},})",
		"(object (a 1) (b 2) (c c) (if 3) (d (object (e (array)))))",
	)
}

@(test)
template_literals_nest :: proc(t: ^testing.T) {
	expect_expression(t, "`abc`", `(template "abc")`)
	expect_expression(t, "`a${x}b${y + 1}c`", `(template "a" x "b" (+ y 1) "c")`)
	expect_expression(t, "`a${`b${c}d`}e`", `(template "a" (template "b" c "d") "e")`)
	expect_expression(t, "`${ {a: {}}.a }`", `(template "" (. (object (a (object))) a) "")`)
}

@(test)
arrows_take_parameters_and_a_body :: proc(t: ^testing.T) {
	expect_expression(t, "x => x * 2", "(arrow [x] (* x 2))")
	expect_expression(t, "() => {}", "(arrow [] (block))")
	expect_expression(t, "() => ({})", "(arrow [] (object))")
	expect_expression(
		t,
		"(a: number, b?: string, ...r: number[]): number => a",
		"(arrow [(a : number) (b? : string) (...r : (number []))] : number a)",
	)
	expect_expression(t, "(a, b) => { return a }", "(arrow [a b] (block (return a)))")
	expect_expression(t, "f(x => y => x + y)", "(call f (arrow [x] (arrow [y] (+ x y))))")
	expect_expression(t, "(a)", "a")
	expect_expression(t, "c ? (x) : y", "(? c x y)")
	expect_expression(t, "c ? (x): T => x : y", "(? c (arrow [x] : T x) y)")
	expect_expression(t, "async(x)", "(call async x)")
}

@(test)
operator_rules_are_syntax_errors :: proc(t: ^testing.T) {
	expect_parse(t, "a ?? b || c", {{.Mixed_Coalesce, 1, 3}}, "(expr (?? a (|| b c)))")
	expect_errors(t, "a || b ?? c", {{.Mixed_Coalesce, 1, 8}})
	expect_errors(t, "a && b ?? c", {{.Mixed_Coalesce, 1, 8}})
	expect_errors(t, "(a || b) ?? c", {})
	expect_errors(t, "a ?? (b || c)", {})

	expect_errors(t, "-2 ** 2", {{.Unary_Before_Power, 1, 1}})
	expect_errors(t, "typeof a ** 2", {{.Unary_Before_Power, 1, 1}})
	expect_errors(t, "(-2) ** 2", {})
	expect_errors(t, "2 ** -2", {})
	expect_errors(t, "++a ** 2", {})
	parsed := expect_errors(t, "!a ** 2", {{.Unary_Before_Power, 1, 1}})
	testing.expect_value(t, parsed.diagnostics[0].args[0], "!")

	expect_errors(t, "f() = 1", {{.Invalid_Assignment_Target, 1, 1}})
	expect_errors(t, "a + b = c", {{.Invalid_Assignment_Target, 1, 1}})
	expect_errors(t, "1 = 2", {{.Invalid_Assignment_Target, 1, 1}})
	expect_errors(t, "++1", {{.Invalid_Assignment_Target, 1, 3}})
	expect_errors(t, "f()++", {{.Invalid_Assignment_Target, 1, 1}})
}

@(test)
expression_constructs_outside_the_subset_are_reported :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:  string,
		error: Error,
		dump:  string,
	} {
		{"new Map()", {.New_Expression, 1, 1}, "(expr bad)"},
		{"new a.B<T>(x)", {.New_Expression, 1, 1}, "(expr bad)"},
		{"this.x = 1", {.Class, 1, 1}, "(expr (= (. bad x) 1))"},
		{"super.f()", {.Class, 1, 1}, "(expr (call (. bad f)))"},
		{"x = class {}", {.Class, 1, 5}, "(expr (= x bad))"},
		{"await f()", {.Async, 1, 1}, "(expr bad)"},
		{"f(async () => 1)", {.Async, 1, 3}, "(expr (call f bad))"},
		{"f(async x => 1)", {.Async, 1, 3}, "(expr (call f bad))"},
		{"f(...xs)", {.Spread, 1, 3}, "(expr (call f bad))"},
		{"[1, ...xs]", {.Spread, 1, 5}, "(expr (array 1 bad))"},
		{"({a, ...o})", {.Spread, 1, 6}, "(expr (object (a a)))"},
		{"a?.b", {.Optional_Chaining, 1, 2}, "(expr bad)"},
		{"a?.[0]", {.Optional_Chaining, 1, 2}, "(expr bad)"},
		{"f?.()", {.Optional_Chaining, 1, 2}, "(expr bad)"},
		{"[a, b] = [b, a]", {.Destructuring, 1, 1}, "(expr bad)"},
		{"f(function () {})", {.Function_Expression, 1, 3}, "(expr (call f bad))"},
		{"({ m() { return 1 } })", {.Function_Expression, 1, 4}, "(expr (object))"},
		{"s.match(/ab+c/g)", {.Regular_Expression, 1, 9}, "(expr (call (. s match) bad))"},
		{"a, b", {.Unsupported_Syntax, 1, 2}, "(expr bad)"},
		{"k in o", {.Unsupported_Syntax, 1, 3}, "(expr bad)"},
		{"a instanceof B", {.Unsupported_Syntax, 1, 3}, "(expr bad)"},
		{"void 0", {.Unsupported_Syntax, 1, 1}, "(expr bad)"},
		{"tag`x`", {.Unsupported_Syntax, 1, 4}, "(expr bad)"},
		{"<T>x", {.Unsupported_Syntax, 1, 1}, "(expr bad)"},
		{"f(<T>(x: T) => x)", {.Unsupported_Syntax, 1, 3}, "(expr (call f bad))"},
		{"x as const", {.Unsupported_Syntax, 1, 3}, "(expr bad)"},
		{"x satisfies T", {.Unsupported_Syntax, 1, 3}, "(expr bad)"},
		{"xs.map<number>(f)", {.Unsupported_Syntax, 1, 7}, "(expr (call (. xs map) f))"},
		{"[1, , 2]", {.Unsupported_Syntax, 1, 5}, "(expr (array 1 2))"},
		{"({ get x() { return 1 } })", {.Unsupported_Syntax, 1, 4}, "(expr (object))"},
		{"({ [k]: 1 })", {.Unsupported_Syntax, 1, 4}, "(expr (object))"},
		{"import(\"./m\")", {.Unsupported_Syntax, 1, 1}, "(expr (call bad \"./m\"))"},
	}
	for c in cases {
		expect_parse(t, c.text, {c.error}, c.dump)
	}
}
