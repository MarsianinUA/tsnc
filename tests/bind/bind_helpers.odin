package bind_tests

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

import "../../src/ast"
import "../../src/bind"
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

Bound :: struct {
	text:         string,
	tree:         ast.File_AST,
	file:         source.File,
	bound:        bind.Bound_File,
	parse_errors: []Error,
	errors:       []Error, // bind's own diagnostics, in print order
}

// bind_text parses and binds text as file 0 into the temp allocator, which the test runner frees
// before each test, and checks the invariants of the result (check_bound).
bind_text :: proc(t: ^testing.T, text: string, loc := #caller_location) -> Bound {
	tree, parse_diagnostics := parse.parse_file(text, 0, context.temp_allocator)
	bound, bind_diagnostics := bind.bind_file(&tree, context.temp_allocator)
	diag.sort(bind_diagnostics)
	file := source.make_file("test.ts", text, context.temp_allocator)

	result := Bound {
		text         = text,
		tree         = tree,
		file         = file,
		bound        = bound,
		parse_errors = errors_of(file, parse_diagnostics),
		errors       = errors_of(file, bind_diagnostics),
	}
	check_bound(t, result, loc)
	return result
}

// expect_bound binds text that must parse and bind without a single diagnostic.
expect_bound :: proc(t: ^testing.T, text: string, loc := #caller_location) -> Bound {
	b := bind_text(t, text, loc)
	testing.expectf(t, len(b.parse_errors) == 0, "%q: parse %v", text, b.parse_errors, loc = loc)
	testing.expectf(t, len(b.errors) == 0, "%q: bind %v", text, b.errors, loc = loc)
	return b
}

// expect_errors binds text and checks the diagnostics bind reports, in print order.
expect_errors :: proc(
	t: ^testing.T,
	text: string,
	expected: []Error,
	loc := #caller_location,
) -> Bound {
	b := bind_text(t, text, loc)
	testing.expectf(t, len(b.parse_errors) == 0, "%q: parse %v", text, b.parse_errors, loc = loc)
	testing.expectf(
		t,
		slice.equal(b.errors, expected),
		"%q: errors %v, want %v",
		text,
		b.errors,
		expected,
		loc = loc,
	)
	return b
}

// Reading the result.

// symbol_named is the symbol declared first under that name in that meaning.
symbol_named :: proc(b: Bound, name: string, meaning := bind.Meaning.Value) -> bind.Symbol_ID {
	for symbol, i in b.bound.symbols[1:] {
		if symbol.name.text == name && meaning in bind.meanings(symbol.kind) {
			return bind.Symbol_ID(i + 1)
		}
	}
	return bind.NO_SYMBOL
}

symbol_of :: proc(b: Bound, name: string, meaning := bind.Meaning.Value) -> bind.Symbol {
	return b.bound.symbols[symbol_named(b, name, meaning)]
}

// use_node is the node of a use of name: the occurrence-th ast.Ident with that text, counted from
// the start of the file.
use_node :: proc(b: Bound, name: string, occurrence := 0) -> ast.Node_ID {
	seen := 0
	for node, id in b.tree.nodes {
		identifier, is_ident := node.variant.(ast.Ident)
		if !is_ident || identifier.name != name {
			continue
		}
		if seen == occurrence {
			return ast.Node_ID(id)
		}
		seen += 1
	}
	return ast.NO_NODE
}

// type_use_node is the node of a use of name as a type: the occurrence-th ast.Type_Ref with that
// text.
type_use_node :: proc(b: Bound, name: string, occurrence := 0) -> ast.Node_ID {
	seen := 0
	for node, id in b.tree.nodes {
		reference, is_reference := node.variant.(ast.Type_Ref)
		if !is_reference || reference.name.text != name {
			continue
		}
		if seen == occurrence {
			return ast.Node_ID(id)
		}
		seen += 1
	}
	return ast.NO_NODE
}

// use_declaration is where the declaration that a use of name refers to stands. It is {} when the
// name resolves to nothing, which means check looks it up among the lib names.
use_declaration :: proc(b: Bound, name: string, occurrence := 0) -> source.Position {
	return declaration_position(b, b.bound.node_symbols[use_node(b, name, occurrence)])
}

// type_use_declaration is use_declaration for a name used as a type.
type_use_declaration :: proc(b: Bound, name: string, occurrence := 0) -> source.Position {
	return declaration_position(b, b.bound.node_symbols[type_use_node(b, name, occurrence)])
}

@(private = "file")
declaration_position :: proc(b: Bound, symbol: bind.Symbol_ID) -> source.Position {
	if symbol == bind.NO_SYMBOL {
		return {}
	}
	return source.position(b.file, b.bound.symbols[symbol].name.span.start)
}

// use_flow is the flow at a use of name, the point check narrows from.
use_flow :: proc(b: Bound, name: string, occurrence := 0) -> bind.Flow_ID {
	return b.bound.node_flow[use_node(b, name, occurrence)]
}

// body_end_flow is the flow at the end of the body of a function declaration, which is UNREACHABLE
// when every path returns.
body_end_flow :: proc(b: Bound, name: string) -> bind.Flow_ID {
	for node in b.tree.nodes {
		function, is_function := node.variant.(ast.Function_Decl)
		if is_function && function.name.text == name {
			return b.bound.node_flow[function.body]
		}
	}
	return bind.UNREACHABLE
}

// scope_named is the scope the node that declares name opens.
scope_of_symbol :: proc(b: Bound, name: string, meaning := bind.Meaning.Value) -> bind.Scope {
	return b.bound.scopes[symbol_of(b, name, meaning).scope]
}

// function_scope_of is the scope of the function a name stands for: a function declaration, or a
// variable that holds an arrow.
function_scope_of :: proc(b: Bound, name: string) -> bind.Scope_ID {
	node := symbol_of(b, name).declaration
	if declarator, is_declarator := b.tree.nodes[node].variant.(ast.Declarator); is_declarator {
		node = declarator.init
	}
	return b.bound.node_scopes[node]
}

// capture_names lists what the function that name stands for captures, as it captured them.
capture_names :: proc(b: Bound, function: string) -> []string {
	return scope_captures(b, b.bound.scopes[function_scope_of(b, function)])
}

// scope_captures lists what a scope captures, in the order it captured them.
scope_captures :: proc(b: Bound, scope: bind.Scope) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for captured in scope.captures {
		append(&names, b.bound.symbols[captured].name.text)
	}
	return names[:]
}

// Flow dumps.

// flow_dump writes the flow graph from flow backwards, as nested calls:
//
//	(join (if "c" start) (else "c" start))
//
// A path that leads back to a node already written prints `^`, so that a loop prints once.
flow_dump :: proc(b: Bound, flow: bind.Flow_ID) -> string {
	builder := strings.builder_make(context.temp_allocator)
	open: [dynamic]bind.Flow_ID
	defer delete(open)
	write_flow(&builder, b, flow, &open)
	return strings.to_string(builder)
}

@(private = "file")
write_flow :: proc(
	builder: ^strings.Builder,
	b: Bound,
	flow: bind.Flow_ID,
	open: ^[dynamic]bind.Flow_ID,
) {
	if slice.contains(open[:], flow) {
		strings.write_string(builder, "^") // a back edge into a node already written
		return
	}
	append(open, flow)
	defer pop(open)

	switch node in b.bound.flow[flow] {
	case bind.Flow_Unreachable:
		strings.write_string(builder, "unreachable")
	case bind.Flow_Start:
		strings.write_string(builder, "start")
	case bind.Flow_Branch:
		write_antecedents(builder, b, "join", node.antecedents, open)
	case bind.Flow_Loop:
		write_antecedents(builder, b, "loop", node.antecedents, open)
	case bind.Flow_Assignment:
		write_step(builder, b, "=", node.node, node.antecedent, open)
	case bind.Flow_Condition:
		write_step(builder, b, condition_word(node), node.condition, node.antecedent, open)
	case bind.Flow_Switch_Clause:
		fmt.sbprintf(builder, "(case %d..%d ", node.clause_start, node.clause_end)
		write_flow(builder, b, node.antecedent, open)
		strings.write_string(builder, ")")
	case bind.Flow_Call:
		write_step(builder, b, "call", node.call, node.antecedent, open)
	}
}

@(private = "file")
condition_word :: proc(node: bind.Flow_Condition) -> string {
	switch node.kind {
	case .Truthy:
		return "if" if node.assume_true else "else"
	case .Not_Nullish:
		return "defined" if node.assume_true else "nullish"
	}
	return ""
}

@(private = "file")
write_step :: proc(
	builder: ^strings.Builder,
	b: Bound,
	word: string,
	node: ast.Node_ID,
	antecedent: bind.Flow_ID,
	open: ^[dynamic]bind.Flow_ID,
) {
	fmt.sbprintf(builder, "(%s %q ", word, node_text(b, node))
	write_flow(builder, b, antecedent, open)
	strings.write_string(builder, ")")
}

@(private = "file")
write_antecedents :: proc(
	builder: ^strings.Builder,
	b: Bound,
	word: string,
	antecedents: []bind.Flow_ID,
	open: ^[dynamic]bind.Flow_ID,
) {
	fmt.sbprintf(builder, "(%s", word)
	for antecedent in antecedents {
		strings.write_string(builder, " ")
		write_flow(builder, b, antecedent, open)
	}
	strings.write_string(builder, ")")
}

// node_text is the source text of a node, on one line.
@(private = "file")
node_text :: proc(b: Bound, id: ast.Node_ID) -> string {
	span := b.tree.nodes[id].span
	text := b.text[span.start:span.end]
	fields := strings.fields(text, context.temp_allocator)
	return strings.join(fields, " ", context.temp_allocator)
}

// Invariants.

// check_bound checks what every result of bind_file must satisfy:
// - the tables of node facts are as long as the tree;
// - every identifier in them is in range;
// - a scope reaches MODULE_SCOPE through its parents, and lists the symbols that name it, except
//   the alias of a re-export, which the file cannot name;
// - a flow node follows an older one, except a loop, which the code inside it comes back to.
check_bound :: proc(t: ^testing.T, b: Bound, loc := #caller_location) {
	bound := b.bound
	node_count := len(b.tree.nodes)
	testing.expectf(
		t,
		len(bound.node_symbols) == node_count &&
		len(bound.node_scopes) == node_count &&
		len(bound.node_flow) == node_count,
		"node tables are %d, %d and %d long, want %d",
		len(bound.node_symbols),
		len(bound.node_scopes),
		len(bound.node_flow),
		node_count,
		loc = loc,
	)

	for symbol, i in bound.symbols[1:] {
		id := bind.Symbol_ID(i + 1)
		testing.expectf(
			t,
			int(symbol.scope) < len(bound.scopes) && int(symbol.declaration) < node_count,
			"symbol %v points outside the file",
			symbol,
			loc = loc,
		)
		listed := slice.contains(bound.scopes[symbol.scope].symbols, id)
		testing.expectf(
			t,
			listed || is_reexport(bound, id),
			"symbol %q is in no scope",
			symbol.name.text,
			loc = loc,
		)
	}

	for scope, i in bound.scopes {
		walk := bind.Scope_ID(i)
		for steps := 0; bound.scopes[walk].kind != .Module; steps += 1 {
			walk = bound.scopes[walk].parent
			if !testing.expectf(
				t,
				steps < len(bound.scopes),
				"scope %d has no module",
				i,
				loc = loc,
			) {
				break
			}
		}
		for symbol in scope.symbols {
			testing.expectf(t, symbol != bind.NO_SYMBOL, "scope %d holds no symbol", i, loc = loc)
		}
		for captured in scope.captures {
			home := bound.symbols[captured].scope
			testing.expectf(
				t,
				scope.kind == .Function && home != bind.MODULE_SCOPE,
				"scope %d captures %q",
				i,
				bound.symbols[captured].name.text,
				loc = loc,
			)
		}
	}

	for node, i in bound.flow {
		id := bind.Flow_ID(i)
		switch flow in node {
		case bind.Flow_Unreachable:
			testing.expectf(t, id == bind.UNREACHABLE, "flow %d is unreachable", i, loc = loc)
		case bind.Flow_Start:
		case bind.Flow_Branch:
			testing.expectf(t, len(flow.antecedents) > 1, "join %d has one path", i, loc = loc)
			expect_older(t, id, flow.antecedents, loc)
		case bind.Flow_Loop:
			// A loop nothing enters keeps no path at all. One that does has a path from outside
			// itself, so that check always walks back to a Flow_Start; a body that ends where it
			// began, as `while (true) { }` does, adds the loop itself beside it.
			entered := false
			for antecedent in flow.antecedents {
				entered ||= antecedent != id
			}
			testing.expectf(
				t,
				entered == (len(flow.antecedents) > 0),
				"loop %d has only itself as a path",
				i,
				loc = loc,
			)
		case bind.Flow_Assignment:
			expect_older(t, id, {flow.antecedent}, loc)
		case bind.Flow_Condition:
			expect_older(t, id, {flow.antecedent}, loc)
		case bind.Flow_Switch_Clause:
			expect_older(t, id, {flow.antecedent}, loc)
		case bind.Flow_Call:
			expect_older(t, id, {flow.antecedent}, loc)
		}
	}

	previous := bind.NO_SYMBOL
	for record in bound.imports {
		testing.expectf(
			t,
			record.symbol > previous && bind.is_alias(bound.symbols[record.symbol].kind),
			"import %v is out of order or names no alias",
			record,
			loc = loc,
		)
		previous = record.symbol
	}
}

@(private = "file")
expect_older :: proc(
	t: ^testing.T,
	id: bind.Flow_ID,
	antecedents: []bind.Flow_ID,
	loc := #caller_location,
) {
	for antecedent in antecedents {
		testing.expectf(t, antecedent < id, "flow %d follows %d", id, antecedent, loc = loc)
	}
}

@(private = "file")
is_reexport :: proc(bound: bind.Bound_File, symbol: bind.Symbol_ID) -> bool {
	for entry in bound.exports {
		if entry.symbol == symbol {
			return true
		}
	}
	return false
}

@(private = "file")
errors_of :: proc(file: source.File, diagnostics: []diag.Diagnostic) -> []Error {
	errors := make([]Error, len(diagnostics), context.temp_allocator)
	for d, i in diagnostics {
		position := source.position(file, d.span.start)
		errors[i] = {d.code, position.line, position.column}
	}
	return errors
}

// lines joins its arguments with a newline, for writing a program in a test.
lines :: proc(parts: ..string) -> string {
	return strings.join(parts, "\n", context.temp_allocator)
}
