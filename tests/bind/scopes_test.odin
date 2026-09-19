package bind_tests

import "core:mem/virtual"
import "core:testing"

import "../../src/ast"
import "../../src/bind"
import "../../src/parse"
import "../../src/source"

@(test)
a_use_resolves_to_the_innermost_declaration :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"let x = 1;", //
			"function f(x: number) {",
			"\tx;",
			"\t{",
			"\t\tlet x = 3;",
			"\t\tx;",
			"\t}",
			"}",
			"x;",
		),
	)
	expect_declaration(t, b, "x", 0, {line = 2, column = 12}) // the parameter
	expect_declaration(t, b, "x", 1, {line = 5, column = 7}) // the inner block
	expect_declaration(t, b, "x", 2, {line = 1, column = 5}) // the module
}

@(test)
a_name_is_visible_before_its_declaration :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function first() { return second() }", //
			"function second() { return later }",
			"let later = 1;",
		),
	)
	expect_declaration(t, b, "second", 0, {line = 2, column = 10})
	expect_declaration(t, b, "later", 0, {line = 3, column = 5})
}

@(test)
a_loop_header_and_its_body_are_different_scopes :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"for (let i = 0; i < 3; i++) {", //
			"\tlet i = 9;",
			"\ti;",
			"}",
			"for (const item of items) { item; }",
		),
	)
	expect_declaration(t, b, "i", 0, {line = 1, column = 10}) // the condition
	expect_declaration(t, b, "i", 1, {line = 1, column = 10}) // the update
	expect_declaration(t, b, "i", 2, {line = 2, column = 6}) // the body
	expect_declaration(t, b, "item", 0, {line = 5, column = 12})
	testing.expect(t, use_declaration(b, "items") == {}) // a name the file does not declare
}

@(test)
a_value_and_a_type_may_share_a_name :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"interface Shape { size: number }", //
			"declare const Shape: Shape;",
			"const s: Shape = Shape;",
		),
	)
	expect_declaration(t, b, "Shape", 0, {line = 2, column = 15}) // the value
	expect_type_declaration(t, b, "Shape", 0, {line = 1, column = 11}) // the annotation of the const
	expect_type_declaration(t, b, "Shape", 1, {line = 1, column = 11})

	value := symbol_of(b, "Shape", .Value)
	type := symbol_of(b, "Shape", .Type)
	testing.expectf(t, value.kind == .Const, "the value is %v", value.kind)
	testing.expectf(t, type.kind == .Interface, "the type is %v", type.kind)
}

@(test)
type_parameters_are_names_of_their_declaration :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"interface Box<T> { value: T }", //
			"type Pair<A> = { first: A; second: A };",
			"function identity<U>(value: U): U { return value }",
			"type Mapper = <V>(value: V) => V;",
		),
	)
	expect_type_declaration(t, b, "T", 0, {line = 1, column = 15})
	expect_type_declaration(t, b, "A", 0, {line = 2, column = 11})
	expect_type_declaration(t, b, "A", 1, {line = 2, column = 11})
	expect_type_declaration(t, b, "U", 0, {line = 3, column = 19})
	expect_type_declaration(t, b, "V", 0, {line = 4, column = 16})

	// Each of them belongs to the declaration that names it, not to the module.
	for name in ([]string{"T", "A", "U", "V"}) {
		scope := scope_of_symbol(b, name, .Type)
		testing.expectf(t, scope.kind != .Module, "%s is in a %v scope", name, scope.kind)
	}
}

@(test)
a_name_no_file_declares_stays_unresolved :: proc(t: ^testing.T) {
	b := expect_bound(t, "console.log(undefined, NaN);")
	testing.expect(t, use_declaration(b, "console") == {})
	testing.expect(t, use_declaration(b, "undefined") == {})
	testing.expect(t, use_declaration(b, "NaN") == {})
}

@(test)
a_second_declaration_of_a_name_is_reported :: proc(t: ^testing.T) {
	expect_errors(t, "let x = 1; let x = 2;", {{.Redeclared_Name, 1, 16}})
	expect_errors(t, "let f = 1; function f() {}", {{.Redeclared_Name, 1, 21}})
	expect_errors(t, "function f(a: number, a: number) {}", {{.Redeclared_Name, 1, 23}})
	expect_errors(t, "function f(a: number) { let a = 1; }", {{.Redeclared_Name, 1, 29}})
	expect_errors(
		t,
		"interface P { x: number } interface P { y: number }",
		{{.Redeclared_Name, 1, 37}},
	)
	expect_errors(t, "function f<T, T>(x: T): T { return x }", {{.Redeclared_Name, 1, 15}})
	expect_errors(
		t,
		lines(
			`import { a } from "./m";`, //
			"const a = 1;",
		),
		{{.Redeclared_Name, 2, 7}},
	)
	expect_errors(
		t,
		"switch (1) { case 1: let a = 1; break; case 2: let a = 2; }",
		{{.Redeclared_Name, 1, 52}},
	)

	// A name of another scope, or of the other meaning, is free.
	expect_bound(t, "let x = 1; { let x = 2; }")
	expect_bound(t, "for (let i = 0; i < 3; i++) { let i = 9; }")
	expect_bound(t, "type T = number; const T = 1;")
	expect_bound(t, "function f(x: number) { { let x = 1; } }")
}

@(test)
a_name_parse_could_not_read_declares_nothing :: proc(t: ^testing.T) {
	// Destructuring is outside the subset: parse keeps the declarator with an empty name, and two
	// of them must not collide with each other.
	b := bind_text(t, lines("const { a } = point;", "const { b } = point;"))
	testing.expectf(t, len(b.errors) == 0, "bind %v", b.errors)
	for symbol in b.bound.symbols[1:] {
		testing.expectf(t, symbol.name.text != "", "declared the empty name %v", symbol)
	}
}

@(test)
the_body_of_a_function_reads_the_scope_that_holds_its_names :: proc(t: ^testing.T) {
	b := expect_bound(t, "function f(x: number) { let y = 1; }")
	body := b.tree.nodes[symbol_of(b, "f").declaration].variant.(ast.Function_Decl).body
	scope := b.bound.node_scopes[body]
	testing.expectf(t, b.bound.scopes[scope].kind == .Function, "the body opens a %v scope", scope)
	testing.expect(t, bind.lookup(b.bound, scope, "x", .Value) != bind.NO_SYMBOL)
	testing.expect(t, bind.lookup(b.bound, scope, "y", .Value) != bind.NO_SYMBOL)
}

@(test)
the_result_outlives_the_scratch_of_the_binding :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	text := "function outer() { let total = 0; return () => { total = total + 1; }; }"
	tree, _ := parse.parse_file(text, 0, allocator)
	bound, _ := bind.bind_file(&tree, allocator)
	free_all(context.temp_allocator) // the scratch of the binding is gone

	total := bind.NO_SYMBOL
	for scope in bound.scopes {
		for symbol in scope.symbols {
			if bound.symbols[symbol].name.text == "total" {
				total = symbol
			}
		}
		for captured in scope.captures {
			testing.expect(t, bound.symbols[captured].name.text == "total")
		}
	}
	testing.expect(t, total != bind.NO_SYMBOL && .Captured in bound.symbols[total].flags)
	for node in bound.flow {
		#partial switch flow in node {
		case bind.Flow_Branch:
			testing.expect(t, len(flow.antecedents) > 1)
		case bind.Flow_Loop:
			testing.expect(t, len(flow.antecedents) > 0)
		}
	}
}

@(test)
every_scope_knows_the_node_that_opens_it :: proc(t: ^testing.T) {
	b := expect_bound(t, "function f() { { let x = 1; } }")
	testing.expect(t, b.bound.scopes[bind.MODULE_SCOPE].kind == .Module)
	for scope, i in b.bound.scopes {
		testing.expectf(
			t,
			b.bound.node_scopes[scope.node] == bind.Scope_ID(i),
			"scope %d and node %d disagree",
			i,
			scope.node,
		)
	}
}

@(private = "file")
expect_declaration :: proc(
	t: ^testing.T,
	b: Bound,
	name: string,
	occurrence: int,
	expected: source.Position,
	loc := #caller_location,
) {
	got := use_declaration(b, name, occurrence)
	testing.expectf(
		t,
		got == expected,
		"%s #%d: %v, want %v",
		name,
		occurrence,
		got,
		expected,
		loc = loc,
	)
}

@(private = "file")
expect_type_declaration :: proc(
	t: ^testing.T,
	b: Bound,
	name: string,
	occurrence: int,
	expected: source.Position,
	loc := #caller_location,
) {
	got := type_use_declaration(b, name, occurrence)
	testing.expectf(
		t,
		got == expected,
		"type %s #%d: %v, want %v",
		name,
		occurrence,
		got,
		expected,
		loc = loc,
	)
}
