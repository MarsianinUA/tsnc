package bind_tests

import "core:slice"
import "core:testing"

import "../../src/ast"
import "../../src/bind"

@(test)
a_closure_captures_the_names_of_the_function_around_it :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function counter(step: number) {", //
			"\tlet total = 0;",
			"\tconst add = () => { total = total + step; };",
			"\treturn add;",
			"}",
		),
	)
	expect_captures(t, b, "add", {"total", "step"})
	expect_flags(t, b, "total", {.Assigned, .Captured})
	expect_flags(t, b, "step", {.Captured})
}

@(test)
a_capture_reaches_through_every_function_in_between :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function outer() {", //
			"\tconst value = 1;",
			"\treturn () => () => value;",
			"}",
		),
	)
	// Both arrows hold it: the inner one reads it, the outer one passes it on.
	for scope in b.bound.scopes {
		if scope.kind != .Function || scope.node == symbol_of(b, "outer").declaration {
			continue
		}
		names := scope_captures(b, scope)
		testing.expectf(t, slice.equal(names, []string{"value"}), "an arrow captures %v", names)
	}
	expect_flags(t, b, "value", {.Captured})
}

@(test)
a_name_of_a_block_inside_a_function_is_captured_like_a_parameter :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function outer(c: boolean) {", //
			"\tif (c) {",
			"\t\tlet inner = 1;",
			"\t\treturn () => inner;",
			"\t}",
			"\treturn () => 0;",
			"}",
		),
	)
	expect_flags(t, b, "inner", {.Captured})
	expect_flags(t, b, "c", {})
}

@(test)
a_module_name_is_never_captured :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			`import { helper } from "./m";`, //
			"let total = 0;",
			"function add(n: number) { total = total + helper(n); }",
		),
	)
	expect_captures(t, b, "add", {})
	expect_flags(t, b, "total", {.Assigned})
	expect_flags(t, b, "helper", {})
}

@(test)
a_top_level_loop_variable_is_captured_like_any_local :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"const fns = [];", //
			"for (let i = 0; i < 3; i++) {",
			"\tfns.push(() => i);",
			"}",
		),
	)
	expect_flags(t, b, "i", {.Assigned, .Captured})
	for scope in b.bound.scopes {
		if scope.kind == .Function {
			names := scope_captures(b, scope)
			testing.expectf(t, slice.equal(names, []string{"i"}), "the arrow captures %v", names)
		}
	}
}

@(test)
a_type_name_is_not_a_capture :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"function wrap<T>(value: T) {", //
			"\treturn (again: T) => again;",
			"}",
		),
	)
	expect_captures(t, b, "wrap", {})
	for scope in b.bound.scopes {
		if scope.kind != .Function {
			continue
		}
		names := scope_captures(b, scope)
		testing.expectf(t, len(names) == 0, "a function captures %v", names)
	}
}

@(test)
assignment_is_marked_wherever_it_happens :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"let counted = 0;", //
			"const fixed = 1;",
			"let later: number;",
			"function bump() { counted++; later = fixed; }",
		),
	)
	expect_flags(t, b, "counted", {.Assigned})
	expect_flags(t, b, "fixed", {})
	expect_flags(t, b, "later", {.Assigned})
}

@(private = "file")
expect_captures :: proc(
	t: ^testing.T,
	b: Bound,
	function: string,
	expected: []string,
	loc := #caller_location,
) {
	names := capture_names(b, function)
	testing.expectf(
		t,
		slice.equal(names, expected),
		"%s captures %v, want %v",
		function,
		names,
		expected,
		loc = loc,
	)
}

@(private = "file")
expect_flags :: proc(
	t: ^testing.T,
	b: Bound,
	name: string,
	expected: bind.Symbol_Flags,
	loc := #caller_location,
) {
	flags := symbol_of(b, name).flags
	testing.expectf(t, flags == expected, "%s is %v, want %v", name, flags, expected, loc = loc)
}

@(test)
a_use_knows_the_outermost_function_between_it_and_its_declaration :: proc(t: ^testing.T) {
	b := expect_bound(
		t,
		lines(
			"console.log(early);", //
			"function outer() {",
			"\tconst inner = () => early + local;",
			"\tconst local = 1;",
			"\treturn local;",
			"}",
			"const early = 2;",
		),
	)
	Use :: struct {
		name:       string,
		occurrence: int,
		deferred:   bind.Scope_ID,
	}
	uses := [?]Use {
		// Run where they stand: the read at the top, and a function's read of its own variable.
		{"early", 0, bind.MODULE_SCOPE},
		{"local", 1, bind.MODULE_SCOPE},
		// Run later: outer, not the arrow, for the module's name, and the arrow for outer's own.
		{"early", 1, function_scope_of(b, "outer")},
		{"local", 0, function_scope_of(b, "inner")},
	}
	for use in uses {
		node := use_node(b, use.name, use.occurrence)
		testing.expectf(t, node != ast.NO_NODE, "no use %d of %s", use.occurrence, use.name)
		testing.expectf(
			t,
			b.bound.node_deferred[node] == use.deferred,
			"use %d of %s is deferred by %v, want %v",
			use.occurrence,
			use.name,
			b.bound.node_deferred[node],
			use.deferred,
		)
	}
}
