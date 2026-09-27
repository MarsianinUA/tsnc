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
	// The result type in parentheses, followed by the arrow of the arrow function itself.
	expect_expression(
		t,
		"(k: number): ((a: number) => number) => (a: number) => a + k",
		"(arrow [(k : number)] : (=> [(a : number)] number) (arrow [(a : number)] (+ a k)))",
	)
}
