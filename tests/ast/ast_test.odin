package ast_tests

import "core:slice"
import "core:testing"

import "../../src/ast"

// The tree of this file, built by hand the way parse lays it out: the Module at ROOT, the other
// nodes children first. The IDs differ from the visit order, so the walk tests prove that walk
// follows the links rather than the array.
//
//	import { f } from "./m";
//	export function g(x: number): number { return f(x) + 1 }
//
// The tests only read TREE. It is a plain variable because @(rodata) rejects an initializer with
// union values.
TREE := [?]ast.Node {
	{span = {start = 0, end = 81}, variant = ast.Module{statements = {3, 14}}},
	{
		span = {start = 9, end = 10},
		variant = ast.Specifier {
			name = {text = "f", span = {start = 9, end = 10}},
			alias = {text = "f", span = {start = 9, end = 10}},
		},
	},
	{span = {start = 18, end = 23}, variant = ast.String_Literal{value = "./m"}},
	{span = {start = 0, end = 24}, variant = ast.Import_Named{specifiers = {1}, path = 2}},
	{span = {start = 46, end = 52}, variant = ast.Keyword_Type{keyword = .Number}},
	{
		span = {start = 43, end = 52},
		variant = ast.Param{name = {text = "x", span = {start = 43, end = 44}}, type = 4},
	},
	{span = {start = 55, end = 61}, variant = ast.Keyword_Type{keyword = .Number}},
	{span = {start = 71, end = 72}, variant = ast.Ident{name = "f"}},
	{span = {start = 73, end = 74}, variant = ast.Ident{name = "x"}},
	{span = {start = 71, end = 75}, variant = ast.Call{callee = 7, args = {8}}},
	{span = {start = 78, end = 79}, variant = ast.Number_Literal{value = 1}},
	{span = {start = 71, end = 79}, variant = ast.Binary{op = .Add, left = 9, right = 10}},
	{span = {start = 64, end = 79}, variant = ast.Return{value = 11}},
	{span = {start = 62, end = 81}, variant = ast.Block{statements = {12}}},
	{
		span = {start = 25, end = 81},
		variant = ast.Function_Decl {
			modifiers = {.Export},
			name = {text = "g", span = {start = 41, end = 42}},
			params = {5},
			return_type = 6,
			body = 13,
		},
	},
}

@(test)
walk_visits_a_file_in_pre_order_and_source_order :: proc(t: ^testing.T) {
	order := visit_order(TREE[:], ast.ROOT)
	defer delete(order)

	expected := []ast.Node_ID{0, 3, 1, 2, 14, 5, 4, 6, 13, 12, 11, 9, 7, 8, 10}
	testing.expectf(t, slice.equal(order[:], expected), "visited %v", order)
}

@(test)
walk_from_a_subtree_root_stays_in_the_subtree :: proc(t: ^testing.T) {
	block: ast.Node_ID = 13
	order := visit_order(TREE[:], block)
	defer delete(order)

	expected := []ast.Node_ID{13, 12, 11, 9, 7, 8, 10}
	testing.expectf(t, slice.equal(order[:], expected), "visited %v", order)
}

@(test)
walk_on_an_empty_stack_is_done :: proc(t: ^testing.T) {
	stack: [dynamic]ast.Node_ID
	_, ok := ast.walk(TREE[:], &stack)
	testing.expect(t, !ok)
}

// Source order, checked on every node of TREE: each child lies inside its parent's span and after
// the child before it.
@(test)
children_lie_inside_their_parent_in_source_order :: proc(t: ^testing.T) {
	children: [dynamic]ast.Node_ID
	defer delete(children)

	for node, id in TREE {
		clear(&children)
		ast.append_children(&children, node)
		previous_end := node.span.start
		for child in children {
			span := TREE[child].span
			is_in_order := previous_end <= span.start && span.end <= node.span.end
			testing.expectf(
				t,
				is_in_order,
				"node %v: child %v at %v, parent at %v",
				id,
				child,
				span,
				node.span,
			)
			previous_end = span.end
		}
	}
}

@(test)
absent_children_are_skipped :: proc(t: ^testing.T) {
	expect_children(t, ast.For{body = 1}, {1}) // for (;;) {}
	expect_children(t, ast.If{condition = 1, then_branch = 2}, {1, 2}) // if (c) {}
	expect_children(t, ast.Declarator{name = {text = "y"}}, {}) // let y;
	expect_children(t, ast.Return{}, {}) // return;
	expect_children(t, ast.Case{statements = {1}}, {1}) // default: s
	expect_children(t, ast.Export_Named{specifiers = {1}}, {1}) // export { a }
}

// Where source order differs from the order of the IDs, the children still come in source order.
@(test)
children_come_in_source_order :: proc(t: ^testing.T) {
	expect_children(t, ast.Do_While{body = 2, condition = 1}, {2, 1}) // do {} while (c)
	expect_children(t, ast.As{expr = 2, type = 1}, {2, 1}) // a as T
	expect_children(t, ast.Call{callee = 3, args = {1, 2}}, {3, 1, 2}) // f(a, b)
	// <U>(x: T) => U
	expect_children(
		t,
		ast.Function_Type{type_params = {3}, params = {2}, return_type = 1},
		{3, 2, 1},
	)
	// function f<T>(x: T): T {}
	expect_children(
		t,
		ast.Function_Decl{type_params = {4}, params = {3}, return_type = 2, body = 1},
		{4, 3, 2, 1},
	)
	// `a${x}b${y}c`: the parts are strings, only the expressions are children.
	expect_children(t, ast.Template{parts = {"a", "b", "c"}, expressions = {2, 1}}, {2, 1})
}

visit_order :: proc(nodes: []ast.Node, root: ast.Node_ID) -> [dynamic]ast.Node_ID {
	stack: [dynamic]ast.Node_ID
	defer delete(stack)
	append(&stack, root)

	order: [dynamic]ast.Node_ID
	for id in ast.walk(nodes, &stack) {
		append(&order, id)
	}
	return order
}

expect_children :: proc(
	t: ^testing.T,
	variant: ast.Variant,
	expected: []ast.Node_ID,
	loc := #caller_location,
) {
	children: [dynamic]ast.Node_ID
	defer delete(children)

	ast.append_children(&children, {variant = variant})
	testing.expectf(
		t,
		slice.equal(children[:], expected),
		"%v: children %v, expected %v",
		variant,
		children,
		expected,
		loc = loc,
	)
}
