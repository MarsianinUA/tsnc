package parse_tests

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

import "../../src/ast"
import "../../src/diag"
import "../../src/parse"
import "../../src/source"

// Error is a diagnostic the way a user reads it: its code, and the 1-based line and column where
// it starts.
Error :: struct {
	code:   diag.Code,
	line:   i32,
	column: i32,
}

Parsed :: struct {
	tree:        ast.File_AST,
	diagnostics: []diag.Diagnostic, // in print order
	errors:      []Error, // the diagnostics as Errors
}

// parse_checked parses text as file 0 with parse_file into the temp allocator, which the test
// runner frees before each test, and checks the invariants of the tree (check_tree).
parse_checked :: proc(t: ^testing.T, text: string, loc := #caller_location) -> Parsed {
	tree, diagnostics := parse.parse_file(text, 0, context.temp_allocator)
	diag.sort(diagnostics)
	file := source.make_file("test.ts", text, context.temp_allocator)
	errors := make([]Error, len(diagnostics), context.temp_allocator)
	for d, i in diagnostics {
		position := source.position(file, d.span.start)
		errors[i] = {d.code, position.line, position.column}
	}
	check_tree(t, text, tree, diagnostics, loc)
	return {tree = tree, diagnostics = diagnostics, errors = errors}
}

// expect_tree checks that text parses without diagnostics into the top-level statements expected,
// one dump per line.
expect_tree :: proc(t: ^testing.T, text: string, expected: string, loc := #caller_location) {
	parsed := parse_checked(t, text, loc)
	expect_errors_of(t, text, parsed, {}, loc)
	got := dump_statements(parsed.tree)
	testing.expectf(t, got == expected, "%q:\ngot  %s\nwant %s", text, got, expected, loc = loc)
}

// expect_expression checks that text is one expression statement without diagnostics, and the
// dump of its expression.
expect_expression :: proc(t: ^testing.T, text: string, expected: string, loc := #caller_location) {
	expect_tree(t, text, concat("(expr ", expected, ")"), loc)
}

// expect_type checks the dump of type_text parsed as the type of an alias, without diagnostics.
expect_type :: proc(t: ^testing.T, type_text: string, expected: string, loc := #caller_location) {
	text := concat("type T = ", type_text)
	expect_tree(t, text, concat("(type T = ", expected, ")"), loc)
}

// expect_errors checks the diagnostics of text, in print order, and returns the parse.
expect_errors :: proc(
	t: ^testing.T,
	text: string,
	expected: []Error,
	loc := #caller_location,
) -> Parsed {
	parsed := parse_checked(t, text, loc)
	expect_errors_of(t, text, parsed, expected, loc)
	return parsed
}

// expect_parse checks both the diagnostics and the top-level dump of text.
expect_parse :: proc(
	t: ^testing.T,
	text: string,
	expected_errors: []Error,
	expected_dump: string,
	loc := #caller_location,
) {
	parsed := expect_errors(t, text, expected_errors, loc)
	got := dump_statements(parsed.tree)
	testing.expectf(
		t,
		got == expected_dump,
		"%q:\ngot  %s\nwant %s",
		text,
		got,
		expected_dump,
		loc = loc,
	)
}

expect_errors_of :: proc(
	t: ^testing.T,
	text: string,
	parsed: Parsed,
	expected: []Error,
	loc := #caller_location,
) {
	testing.expectf(
		t,
		slice.equal(parsed.errors, expected),
		"%q: errors %v, want %v",
		text,
		parsed.errors,
		expected,
		loc = loc,
	)
}

// check_tree checks what every tree parse_file returns must satisfy:
// - ROOT is a Module over the whole text;
// - every other node has exactly one parent, and lies inside it, after its previous sibling;
// - a list of one kind of node holds only that kind;
// - a Template has one more part than expressions;
// - imports lists the top-level imports and re-exports in order;
// - a Bad node comes with at least one diagnostic.
check_tree :: proc(
	t: ^testing.T,
	text: string,
	tree: ast.File_AST,
	diagnostics: []diag.Diagnostic,
	loc := #caller_location,
) {
	nodes := tree.nodes
	root := nodes[ast.ROOT]
	module, is_module := root.variant.(ast.Module)
	root_span := source.Span {
		end = i32(len(text)),
	}
	if !testing.expectf(
		t,
		is_module && root.span == root_span,
		"%q: root %v",
		text,
		root,
		loc = loc,
	) {
		return
	}

	parent_counts := make([]int, len(nodes), context.temp_allocator)
	children: [dynamic]ast.Node_ID
	defer delete(children)
	has_bad := false
	for node, id in nodes {
		_, is_bad := node.variant.(ast.Bad)
		has_bad ||= is_bad
		testing.expectf(
			t,
			node.span.start <= node.span.end,
			"%q: node %d at %v",
			text,
			id,
			node.span,
			loc = loc,
		)

		clear(&children)
		ast.append_children(&children, node)
		previous_end := node.span.start
		for child in children {
			parent_counts[child] += 1
			span := nodes[child].span
			is_in_order := previous_end <= span.start && span.end <= node.span.end
			testing.expectf(
				t,
				is_in_order,
				"%q: child %d at %v of node %d at %v",
				text,
				child,
				span,
				id,
				node.span,
				loc = loc,
			)
			previous_end = span.end
		}
		check_lists(t, text, nodes, node, loc)
	}
	for count, id in parent_counts[1:] {
		testing.expectf(
			t,
			count == 1,
			"%q: node %d has %d parents",
			text,
			id + 1,
			count,
			loc = loc,
		)
	}

	requests: [dynamic]ast.Node_ID
	defer delete(requests)
	for id in module.statements {
		#partial switch v in nodes[id].variant {
		case ast.Import_Named, ast.Import_Namespace:
			append(&requests, id)
		case ast.Export_Named:
			if v.path != ast.NO_NODE {
				append(&requests, id)
			}
		}
	}
	testing.expectf(
		t,
		slice.equal(tree.imports, requests[:]),
		"%q: imports %v, want %v",
		text,
		tree.imports,
		requests,
		loc = loc,
	)
	testing.expectf(
		t,
		!has_bad || len(diagnostics) > 0,
		"%q: a Bad node without a diagnostic",
		text,
		loc = loc,
	)
}

// check_lists checks that the lists of one kind of node in node hold only that kind.
check_lists :: proc(
	t: ^testing.T,
	text: string,
	nodes: []ast.Node,
	node: ast.Node,
	loc := #caller_location,
) {
	expect_all :: proc(
		t: ^testing.T,
		text: string,
		nodes: []ast.Node,
		ids: []ast.Node_ID,
		$T: typeid,
		loc := #caller_location,
	) {
		for id in ids {
			_, ok := nodes[id].variant.(T)
			testing.expectf(
				t,
				ok,
				"%q: %v in a list of %v",
				text,
				nodes[id].variant,
				typeid_of(T),
				loc = loc,
			)
		}
	}
	#partial switch v in node.variant {
	case ast.Var_Decl:
		expect_all(t, text, nodes, v.declarators, ast.Declarator, loc)
	case ast.Function_Decl:
		expect_all(t, text, nodes, v.type_params, ast.Type_Param, loc)
		expect_all(t, text, nodes, v.params, ast.Param, loc)
	case ast.Interface_Decl:
		expect_all(t, text, nodes, v.type_params, ast.Type_Param, loc)
	case ast.Type_Alias_Decl:
		expect_all(t, text, nodes, v.type_params, ast.Type_Param, loc)
	case ast.Import_Named:
		expect_all(t, text, nodes, v.specifiers, ast.Specifier, loc)
	case ast.Export_Named:
		expect_all(t, text, nodes, v.specifiers, ast.Specifier, loc)
	case ast.Switch:
		expect_all(t, text, nodes, v.cases, ast.Case, loc)
	case ast.Object_Literal:
		expect_all(t, text, nodes, v.properties, ast.Property, loc)
	case ast.Arrow:
		expect_all(t, text, nodes, v.params, ast.Param, loc)
	case ast.Function_Type:
		expect_all(t, text, nodes, v.type_params, ast.Type_Param, loc)
		expect_all(t, text, nodes, v.params, ast.Param, loc)
	case ast.Object_Type:
		expect_all(t, text, nodes, v.members, ast.Property_Signature, loc)
	case ast.Template:
		testing.expectf(
			t,
			len(v.parts) == len(v.expressions) + 1,
			"%q: a template with %d parts and %d expressions",
			text,
			len(v.parts),
			len(v.expressions),
			loc = loc,
		)
	}
}

// Dump.
//
// A node dumps as an S-expression close to the TypeScript it came from, children in source order:
// statements `(let (x : number = 1))`, `(if c (block) _)`; expressions `(+ a b)`, `(call f x)`,
// `(. a name)`, `(x !)`; types `(| A B)`, `(T [])`, `(=> <U> [(x : T)] U)`, `{(x? : T)}`. An absent
// child is `_`, an empty name `_`, a Bad node `bad`.

// dump_statements dumps the top-level statements of tree, one per line.
dump_statements :: proc(tree: ast.File_AST) -> string {
	b := strings.builder_make(context.temp_allocator)
	module := tree.nodes[ast.ROOT].variant.(ast.Module)
	for id, i in module.statements {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		dump(&b, tree.nodes, id)
	}
	return strings.to_string(b)
}

dump :: proc(b: ^strings.Builder, nodes: []ast.Node, id: ast.Node_ID) {
	if id == ast.NO_NODE {
		strings.write_string(b, "_")
		return
	}
	switch v in nodes[id].variant {
	case ast.Bad:
		strings.write_string(b, "bad")
	case ast.Module:
		strings.write_string(b, "(module")
		dump_list(b, nodes, v.statements)
		strings.write_string(b, ")")

	// Declarations and modules.
	case ast.Var_Decl:
		strings.write_string(b, "(")
		dump_modifiers(b, v.modifiers)
		strings.write_string(b, "let" if v.kind == .Let else "const")
		dump_list(b, nodes, v.declarators)
		strings.write_string(b, ")")
	case ast.Declarator:
		if v.type == ast.NO_NODE && v.init == ast.NO_NODE {
			dump_name(b, v.name)
			return
		}
		strings.write_string(b, "(")
		dump_name(b, v.name)
		if v.type != ast.NO_NODE {
			strings.write_string(b, " : ")
			dump(b, nodes, v.type)
		}
		if v.init != ast.NO_NODE {
			strings.write_string(b, " = ")
			dump(b, nodes, v.init)
		}
		strings.write_string(b, ")")
	case ast.Function_Decl:
		strings.write_string(b, "(")
		dump_modifiers(b, v.modifiers)
		strings.write_string(b, "function ")
		dump_name(b, v.name)
		dump_type_params(b, nodes, v.type_params)
		dump_params(b, nodes, v.params)
		if v.return_type != ast.NO_NODE {
			strings.write_string(b, " : ")
			dump(b, nodes, v.return_type)
		}
		strings.write_string(b, " ")
		dump(b, nodes, v.body)
		strings.write_string(b, ")")
	case ast.Param:
		if v.type == ast.NO_NODE && v.kind == .Required {
			dump_name(b, v.name)
			return
		}
		strings.write_string(b, "(..." if v.kind == .Rest else "(")
		dump_name(b, v.name)
		if v.kind == .Optional {
			strings.write_string(b, "?")
		}
		if v.type != ast.NO_NODE {
			strings.write_string(b, " : ")
			dump(b, nodes, v.type)
		}
		strings.write_string(b, ")")
	case ast.Type_Param:
		dump_name(b, v.name)
	case ast.Interface_Decl:
		strings.write_string(b, "(")
		dump_modifiers(b, v.modifiers)
		strings.write_string(b, "interface ")
		dump_name(b, v.name)
		dump_type_params(b, nodes, v.type_params)
		strings.write_string(b, " ")
		dump(b, nodes, v.body)
		strings.write_string(b, ")")
	case ast.Type_Alias_Decl:
		strings.write_string(b, "(")
		dump_modifiers(b, v.modifiers)
		strings.write_string(b, "type ")
		dump_name(b, v.name)
		dump_type_params(b, nodes, v.type_params)
		strings.write_string(b, " = ")
		dump(b, nodes, v.type)
		strings.write_string(b, ")")
	case ast.Import_Named:
		strings.write_string(b, "(import type {" if v.type_only else "(import {")
		dump_list(b, nodes, v.specifiers, first_separator = "")
		strings.write_string(b, "} ")
		dump(b, nodes, v.path)
		strings.write_string(b, ")")
	case ast.Import_Namespace:
		strings.write_string(b, "(import type * as " if v.type_only else "(import * as ")
		dump_name(b, v.name)
		strings.write_string(b, " ")
		dump(b, nodes, v.path)
		strings.write_string(b, ")")
	case ast.Export_Named:
		strings.write_string(b, "(export type {" if v.type_only else "(export {")
		dump_list(b, nodes, v.specifiers, first_separator = "")
		strings.write_string(b, "}")
		if v.path != ast.NO_NODE {
			strings.write_string(b, " ")
			dump(b, nodes, v.path)
		}
		strings.write_string(b, ")")
	case ast.Specifier:
		is_plain := !v.type_only && v.alias.text == v.name.text
		if is_plain {
			dump_name(b, v.name)
			return
		}
		strings.write_string(b, "(type " if v.type_only else "(")
		dump_name(b, v.name)
		if v.alias.text != v.name.text {
			strings.write_string(b, " as ")
			dump_name(b, v.alias)
		}
		strings.write_string(b, ")")

	// Statements.
	case ast.Block:
		strings.write_string(b, "(block")
		dump_list(b, nodes, v.statements)
		strings.write_string(b, ")")
	case ast.Expr_Stmt:
		dump_form(b, nodes, "expr", v.expr)
	case ast.If:
		dump_form(b, nodes, "if", v.condition, v.then_branch, v.else_branch)
	case ast.Switch:
		strings.write_string(b, "(switch ")
		dump(b, nodes, v.value)
		dump_list(b, nodes, v.cases)
		strings.write_string(b, ")")
	case ast.Case:
		if v.value == ast.NO_NODE {
			strings.write_string(b, "(default")
		} else {
			strings.write_string(b, "(case ")
			dump(b, nodes, v.value)
		}
		dump_list(b, nodes, v.statements)
		strings.write_string(b, ")")
	case ast.For:
		dump_form(b, nodes, "for", v.init, v.condition, v.update, v.body)
	case ast.For_Of:
		dump_form(b, nodes, "for-of", v.declaration, v.iterable, v.body)
	case ast.While:
		dump_form(b, nodes, "while", v.condition, v.body)
	case ast.Do_While:
		dump_form(b, nodes, "do", v.body, v.condition)
	case ast.Break:
		strings.write_string(b, "break")
	case ast.Continue:
		strings.write_string(b, "continue")
	case ast.Return:
		if v.value == ast.NO_NODE {
			strings.write_string(b, "(return)")
		} else {
			dump_form(b, nodes, "return", v.value)
		}
	case ast.Empty:
		strings.write_string(b, "empty")

	// Expressions.
	case ast.Ident:
		strings.write_string(b, v.name)
	case ast.Number_Literal:
		fmt.sbprint(b, v.value)
	case ast.String_Literal:
		fmt.sbprintf(b, "%q", v.value)
	case ast.Template:
		strings.write_string(b, "(template")
		for part, i in v.parts {
			fmt.sbprintf(b, " %q", part)
			if i < len(v.expressions) {
				strings.write_string(b, " ")
				dump(b, nodes, v.expressions[i])
			}
		}
		strings.write_string(b, ")")
	case ast.Bool_Literal:
		fmt.sbprint(b, v.value)
	case ast.Null_Literal:
		strings.write_string(b, "null")
	case ast.Array_Literal:
		strings.write_string(b, "(array")
		dump_list(b, nodes, v.elements)
		strings.write_string(b, ")")
	case ast.Object_Literal:
		strings.write_string(b, "(object")
		dump_list(b, nodes, v.properties)
		strings.write_string(b, ")")
	case ast.Property:
		strings.write_string(b, "(")
		dump_name(b, v.name)
		strings.write_string(b, " ")
		dump(b, nodes, v.value)
		strings.write_string(b, ")")
	case ast.Arrow:
		strings.write_string(b, "(arrow")
		dump_params(b, nodes, v.params)
		if v.return_type != ast.NO_NODE {
			strings.write_string(b, " : ")
			dump(b, nodes, v.return_type)
		}
		strings.write_string(b, " ")
		dump(b, nodes, v.body)
		strings.write_string(b, ")")
	case ast.Unary:
		dump_form(b, nodes, UNARY_TEXT[v.op], v.operand)
	case ast.Update:
		switch v.op {
		case .Pre_Increment:
			dump_form(b, nodes, "++", v.operand)
		case .Pre_Decrement:
			dump_form(b, nodes, "--", v.operand)
		case .Post_Increment:
			dump_postfix(b, nodes, v.operand, "++")
		case .Post_Decrement:
			dump_postfix(b, nodes, v.operand, "--")
		}
	case ast.Binary:
		dump_form(b, nodes, BINARY_TEXT[v.op], v.left, v.right)
	case ast.Assign:
		dump_form(b, nodes, ASSIGN_TEXT[v.op], v.target, v.value)
	case ast.Conditional:
		dump_form(b, nodes, "?", v.condition, v.then_value, v.else_value)
	case ast.Call:
		strings.write_string(b, "(call ")
		dump(b, nodes, v.callee)
		dump_list(b, nodes, v.args)
		strings.write_string(b, ")")
	case ast.Member:
		strings.write_string(b, "(. ")
		dump(b, nodes, v.object)
		strings.write_string(b, " ")
		dump_name(b, v.name)
		strings.write_string(b, ")")
	case ast.Index:
		dump_form(b, nodes, "index", v.object, v.index)
	case ast.As:
		dump_form(b, nodes, "as", v.expr, v.type)
	case ast.Non_Null:
		dump_postfix(b, nodes, v.expr, "!")

	// Types.
	case ast.Keyword_Type:
		strings.write_string(b, KEYWORD_TEXT[v.keyword])
	case ast.Literal_Type:
		switch value in v.value {
		case f64:
			fmt.sbprint(b, value)
		case string:
			fmt.sbprintf(b, "%q", value)
		case bool:
			fmt.sbprint(b, value)
		}
	case ast.Type_Ref:
		if len(v.args) > 0 {
			strings.write_string(b, "(")
		}
		if v.qualifier.text != "" {
			strings.write_string(b, v.qualifier.text)
			strings.write_string(b, ".")
		}
		dump_name(b, v.name)
		if len(v.args) > 0 {
			dump_list(b, nodes, v.args)
			strings.write_string(b, ")")
		}
	case ast.Array_Type:
		strings.write_string(b, "(")
		dump(b, nodes, v.element)
		strings.write_string(b, " [])")
	case ast.Union_Type:
		strings.write_string(b, "(|")
		dump_list(b, nodes, v.members)
		strings.write_string(b, ")")
	case ast.Function_Type:
		strings.write_string(b, "(=>")
		dump_type_params(b, nodes, v.type_params)
		dump_params(b, nodes, v.params)
		strings.write_string(b, " ")
		dump(b, nodes, v.return_type)
		strings.write_string(b, ")")
	case ast.Object_Type:
		strings.write_string(b, "{")
		dump_list(b, nodes, v.members, first_separator = "")
		strings.write_string(b, "}")
	case ast.Property_Signature:
		strings.write_string(b, "(")
		if .Readonly in v.flags {
			strings.write_string(b, "readonly ")
		}
		dump_name(b, v.name)
		if .Optional in v.flags {
			strings.write_string(b, "?")
		}
		strings.write_string(b, " : ")
		dump(b, nodes, v.type)
		strings.write_string(b, ")")
	}
}

// dump_form writes `(head child child ...)`.
dump_form :: proc(b: ^strings.Builder, nodes: []ast.Node, head: string, children: ..ast.Node_ID) {
	strings.write_string(b, "(")
	strings.write_string(b, head)
	for child in children {
		strings.write_string(b, " ")
		dump(b, nodes, child)
	}
	strings.write_string(b, ")")
}

dump_postfix :: proc(
	b: ^strings.Builder,
	nodes: []ast.Node,
	operand: ast.Node_ID,
	operator: string,
) {
	strings.write_string(b, "(")
	dump(b, nodes, operand)
	strings.write_string(b, " ")
	strings.write_string(b, operator)
	strings.write_string(b, ")")
}

// dump_list writes each node of ids after a space; the first one after first_separator.
dump_list :: proc(
	b: ^strings.Builder,
	nodes: []ast.Node,
	ids: []ast.Node_ID,
	first_separator := " ",
) {
	for id, i in ids {
		strings.write_string(b, first_separator if i == 0 else " ")
		dump(b, nodes, id)
	}
}

// dump_params writes ` [a (b : T)]`.
dump_params :: proc(b: ^strings.Builder, nodes: []ast.Node, params: []ast.Node_ID) {
	strings.write_string(b, " [")
	dump_list(b, nodes, params, first_separator = "")
	strings.write_string(b, "]")
}

// dump_type_params writes ` <T U>`, or nothing without type parameters.
dump_type_params :: proc(b: ^strings.Builder, nodes: []ast.Node, type_params: []ast.Node_ID) {
	if len(type_params) == 0 {
		return
	}
	strings.write_string(b, " <")
	dump_list(b, nodes, type_params, first_separator = "")
	strings.write_string(b, ">")
}

dump_modifiers :: proc(b: ^strings.Builder, modifiers: ast.Modifiers) {
	if .Export in modifiers {
		strings.write_string(b, "export ")
	}
	if .Declare in modifiers {
		strings.write_string(b, "declare ")
	}
}

dump_name :: proc(b: ^strings.Builder, name: ast.Name) {
	strings.write_string(b, name.text if name.text != "" else "_")
}

@(rodata)
UNARY_TEXT := [ast.Unary_Op]string {
	.Minus   = "-",
	.Plus    = "+",
	.Not     = "!",
	.Bit_Not = "~",
	.Typeof  = "typeof",
}

@(rodata)
BINARY_TEXT := [ast.Binary_Op]string {
	.Add                  = "+",
	.Subtract             = "-",
	.Multiply             = "*",
	.Divide               = "/",
	.Remainder            = "%",
	.Power                = "**",
	.Shift_Left           = "<<",
	.Shift_Right          = ">>",
	.Shift_Right_Unsigned = ">>>",
	.Bit_And              = "&",
	.Bit_Or               = "|",
	.Bit_Xor              = "^",
	.Less                 = "<",
	.Less_Equal           = "<=",
	.Greater              = ">",
	.Greater_Equal        = ">=",
	.Equal                = "==",
	.Not_Equal            = "!=",
	.Strict_Equal         = "===",
	.Strict_Not_Equal     = "!==",
	.And                  = "&&",
	.Or                   = "||",
	.Coalesce             = "??",
}

@(rodata)
ASSIGN_TEXT := [ast.Assign_Op]string {
	.Assign               = "=",
	.Add                  = "+=",
	.Subtract             = "-=",
	.Multiply             = "*=",
	.Divide               = "/=",
	.Remainder            = "%=",
	.Power                = "**=",
	.Shift_Left           = "<<=",
	.Shift_Right          = ">>=",
	.Shift_Right_Unsigned = ">>>=",
	.Bit_And              = "&=",
	.Bit_Or               = "|=",
	.Bit_Xor              = "^=",
	.And                  = "&&=",
	.Or                   = "||=",
	.Coalesce             = "??=",
}

@(rodata)
KEYWORD_TEXT := [ast.Type_Keyword]string {
	.Number    = "number",
	.String    = "string",
	.Boolean   = "boolean",
	.Null      = "null",
	.Undefined = "undefined",
	.Void      = "void",
	.Any       = "any",
	.Unknown   = "unknown",
	.Never     = "never",
}

// concat joins parts into one string in the temp allocator.
concat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

// lines joins parts with line breaks, for texts and dumps of several lines.
lines :: proc(parts: ..string) -> string {
	return strings.join(parts, "\n", context.temp_allocator)
}
