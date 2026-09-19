package bind_tests

import "core:slice"
import "core:testing"

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
