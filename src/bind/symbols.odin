package bind

import "core:slice"

import "../ast"
import "../diag"

// Scope_Build is a scope while bind_file fills it; freeze turns it into a Scope. names is the
// index bind resolves through, and it goes away with the rest of the scratch data.
@(private)
Scope_Build :: struct {
	kind:     Scope_Kind,
	parent:   Scope_ID,
	node:     ast.Node_ID,
	symbols:  [dynamic]Symbol_ID,
	captures: [dynamic]Symbol_ID,
	names:    map[Name_Key]Symbol_ID,
}

// Name_Key is a name in one of its two meanings, which is what a scope holds at most one of.
@(private)
Name_Key :: struct {
	text:    string,
	meaning: Meaning,
}

// Scopes.

// open_scope opens a scope inside the current one and returns the scope to close back to.
@(private)
open_scope :: proc(b: ^Binder, kind: Scope_Kind, node: ast.Node_ID) -> (previous: Scope_ID) {
	id := Scope_ID(len(b.scopes))
	append(
		&b.scopes,
		Scope_Build {
			kind = kind,
			parent = b.scope,
			node = node,
			symbols = make([dynamic]Symbol_ID, context.temp_allocator),
			captures = make([dynamic]Symbol_ID, context.temp_allocator),
			names = make(map[Name_Key]Symbol_ID, context.temp_allocator),
		},
	)
	b.node_scopes[node] = id
	previous = b.scope
	b.scope = id
	return previous
}

@(private)
close_scope :: proc(b: ^Binder, previous: Scope_ID) {
	b.scope = previous
}

// function_of is the .Function scope that runs the code of scope, or MODULE_SCOPE for the
// top-level code.
@(private)
function_of :: proc(b: ^Binder, scope: Scope_ID) -> Scope_ID {
	current := scope
	for b.scopes[current].kind != .Function && b.scopes[current].kind != .Module {
		current = b.scopes[current].parent
	}
	return current
}

// Declarations.

// declare adds a symbol to the current scope. A name parse could not read declares nothing, and a
// meaning that is taken is reported and left with its first declaration.
@(private)
declare :: proc(
	b: ^Binder,
	name: ast.Name,
	kind: Symbol_Kind,
	declaration: ast.Node_ID,
) -> Symbol_ID {
	if name.text == "" {
		return NO_SYMBOL
	}
	symbol := add_symbol(b, name, kind, declaration)
	scope := &b.scopes[b.scope]
	append(&scope.symbols, symbol)

	taken := false
	for meaning in meanings(kind) {
		key := Name_Key{name.text, meaning}
		if key in scope.names {
			taken = true
			continue
		}
		scope.names[key] = symbol
	}
	if taken {
		report(b, .Redeclared_Name, name)
	}
	return symbol
}

// add_symbol records a symbol and the node that declares it. The symbol of a re-export goes
// through here alone: the file cannot name it.
@(private)
add_symbol :: proc(
	b: ^Binder,
	name: ast.Name,
	kind: Symbol_Kind,
	declaration: ast.Node_ID,
) -> Symbol_ID {
	id := Symbol_ID(len(b.symbols))
	append(
		&b.symbols,
		Symbol{name = name, kind = kind, scope = b.scope, declaration = declaration},
	)
	b.node_symbols[declaration] = id
	return id
}

// declare_statements declares what a list of statements introduces, before any of it is bound: a
// name is visible in the whole scope that holds it, so a use may come before its declaration.
@(private)
declare_statements :: proc(b: ^Binder, statements: []ast.Node_ID) {
	for id in statements {
		declare_statement(b, id)
	}
}

@(private)
declare_statement :: proc(b: ^Binder, id: ast.Node_ID) {
	if id == ast.NO_NODE {
		return
	}
	#partial switch v in b.tree.nodes[id].variant {
	case ast.Var_Decl:
		kind := Symbol_Kind.Const if v.kind == .Const else Symbol_Kind.Let
		for declarator_id in v.declarators {
			declarator := b.tree.nodes[declarator_id].variant.(ast.Declarator)
			declare(b, declarator.name, kind, declarator_id)
		}
	case ast.Function_Decl:
		declare(b, v.name, .Function, id)
	case ast.Interface_Decl:
		declare(b, v.name, .Interface, id)
	case ast.Type_Alias_Decl:
		declare(b, v.name, .Type_Alias, id)
	case ast.Import_Named:
		for specifier_id in v.specifiers {
			specifier := b.tree.nodes[specifier_id].variant.(ast.Specifier)
			symbol := declare(b, specifier.alias, .Import, specifier_id)
			add_import(b, symbol, specifier.name, id, v.type_only || specifier.type_only)
		}
	case ast.Import_Namespace:
		symbol := declare(b, v.name, .Namespace_Import, id)
		add_import(b, symbol, {}, id, v.type_only) // `* as m` names no single export
	case ast.Export_Named:
		if v.path == ast.NO_NODE {
			return // an export list of local names; collect_exports resolves them
		}
		for specifier_id in v.specifiers {
			specifier := b.tree.nodes[specifier_id].variant.(ast.Specifier)
			if specifier.alias.text == "" {
				continue
			}
			// A re-exported name is not visible in this file, so its symbol joins no scope.
			symbol := add_symbol(b, specifier.alias, .Import, specifier_id)
			add_import(b, symbol, specifier.name, id, v.type_only || specifier.type_only)
		}
	}
}

// add_import records what an alias symbol stands for in the module the request names.
@(private)
add_import :: proc(
	b: ^Binder,
	symbol: Symbol_ID,
	name: ast.Name,
	request: ast.Node_ID,
	type_only: bool,
) {
	if symbol == NO_SYMBOL {
		return
	}
	append(
		&b.imports,
		Import{symbol = symbol, name = name, request = request, type_only = type_only},
	)
}

// Uses.

// resolve records which symbol the use at id names, and returns it. A name no scope of this file
// holds stays NO_SYMBOL: check looks it up among the lib names.
@(private)
resolve :: proc(b: ^Binder, id: ast.Node_ID, name: ast.Name, meaning: Meaning) -> Symbol_ID {
	if name.text == "" {
		return NO_SYMBOL
	}
	symbol := NO_SYMBOL
	scope := b.scope
	for {
		if found, ok := b.scopes[scope].names[Name_Key{name.text, meaning}]; ok {
			symbol = found
			break
		}
		if b.scopes[scope].kind == .Module {
			break
		}
		scope = b.scopes[scope].parent
	}
	b.node_symbols[id] = symbol
	if meaning == .Value {
		capture(b, symbol)
	}
	return symbol
}

// capture notes that the current function uses a symbol of an enclosing one: the symbol lives in
// the closure's environment, and so it does in every function in between. A module global is a
// cell of the program instead, and belongs to no environment.
@(private)
capture :: proc(b: ^Binder, symbol: Symbol_ID) {
	if symbol == NO_SYMBOL {
		return
	}
	home := b.symbols[symbol].scope
	if home == MODULE_SCOPE {
		return
	}
	container := function_of(b, home)
	if container == b.function {
		return
	}
	b.symbols[symbol].flags += {.Captured}
	for scope := b.function;
	    scope != container && scope != MODULE_SCOPE;
	    scope = function_of(b, b.scopes[scope].parent) {
		captures := &b.scopes[scope].captures
		if !slice.contains(captures[:], symbol) {
			append(captures, symbol)
		}
	}
}

// mark_assigned notes that a variable changes after its declaration, which decides whether lower
// may copy it into a closure.
@(private)
mark_assigned :: proc(b: ^Binder, target: ast.Node_ID) {
	if target == ast.NO_NODE {
		return
	}
	if _, is_ident := b.tree.nodes[target].variant.(ast.Ident); !is_ident {
		return
	}
	symbol := b.node_symbols[target]
	if symbol != NO_SYMBOL {
		b.symbols[symbol].flags += {.Assigned}
	}
}

// Exports.

// collect_exports fills the export table from the top-level statements, after everything is bound:
// an export list names symbols of the module scope.
@(private)
collect_exports :: proc(b: ^Binder, statements: []ast.Node_ID) {
	taken := make(map[Name_Key]struct{}, context.temp_allocator)
	defer delete(taken)

	for id in statements {
		#partial switch v in b.tree.nodes[id].variant {
		case ast.Var_Decl:
			if .Export not_in v.modifiers {
				continue
			}
			for declarator_id in v.declarators {
				declarator := b.tree.nodes[declarator_id].variant.(ast.Declarator)
				add_export(b, &taken, declarator.name, b.node_symbols[declarator_id], false)
			}
		case ast.Function_Decl:
			if .Export in v.modifiers {
				add_export(b, &taken, v.name, b.node_symbols[id], false)
			}
		case ast.Interface_Decl:
			if .Export in v.modifiers {
				add_export(b, &taken, v.name, b.node_symbols[id], false)
			}
		case ast.Type_Alias_Decl:
			if .Export in v.modifiers {
				add_export(b, &taken, v.name, b.node_symbols[id], false)
			}
		case ast.Export_Named:
			for specifier_id in v.specifiers {
				specifier := b.tree.nodes[specifier_id].variant.(ast.Specifier)
				type_only := v.type_only || specifier.type_only
				if v.path != ast.NO_NODE {
					add_export(b, &taken, specifier.alias, b.node_symbols[specifier_id], type_only)
					continue
				}
				export_local(b, &taken, specifier, type_only)
			}
		}
	}
}

// export_local exports a name the module declares. A name that is both a type and a value, as the
// lib file's `Math` is, becomes one entry per meaning.
@(private)
export_local :: proc(
	b: ^Binder,
	taken: ^map[Name_Key]struct{},
	specifier: ast.Specifier,
	type_only: bool,
) {
	value := module_symbol(b, specifier.name.text, .Value)
	type := module_symbol(b, specifier.name.text, .Type)
	if value == NO_SYMBOL && type == NO_SYMBOL {
		if specifier.name.text != "" {
			report(b, .Undeclared_Export, specifier.name)
		}
		add_export(b, taken, specifier.alias, NO_SYMBOL, type_only)
		return
	}
	if type_only {
		add_export(b, taken, specifier.alias, type if type != NO_SYMBOL else value, true)
		return
	}
	if value != NO_SYMBOL {
		add_export(b, taken, specifier.alias, value, false)
	}
	if type != NO_SYMBOL && type != value {
		add_export(b, taken, specifier.alias, type, false)
	}
}

// module_symbol is the symbol the module scope holds under a name, while bind_file still has its
// index.
@(private)
module_symbol :: proc(b: ^Binder, name: string, meaning: Meaning) -> Symbol_ID {
	symbol, ok := b.scopes[MODULE_SCOPE].names[Name_Key{name, meaning}]
	return symbol if ok else NO_SYMBOL
}

// add_export adds one export entry and reports a name exported twice in the same meaning.
@(private)
add_export :: proc(
	b: ^Binder,
	taken: ^map[Name_Key]struct{},
	name: ast.Name,
	symbol: Symbol_ID,
	type_only: bool,
) {
	if name.text == "" {
		return
	}
	entry := Export {
		name      = name,
		symbol    = symbol,
		type_only = type_only,
	}
	duplicate := false
	for meaning in export_meanings(b.symbols[:], entry) {
		key := Name_Key{name.text, meaning}
		if key in taken^ {
			duplicate = true
			continue
		}
		taken^[key] = {}
	}
	if duplicate {
		report(b, .Duplicate_Export, name)
	}
	append(&b.exports, entry)
}

// Side effects.

// module_has_effects reports whether the top level of the module runs code when the module loads.
// Declarations and constants that hold a value of their own do not: two modules that import each
// other are safe as long as neither runs anything, since then neither can read the other before it
// is ready.
@(private)
module_has_effects :: proc(b: ^Binder, statements: []ast.Node_ID) -> bool {
	for id in statements {
		if statement_has_effects(b, id) {
			return true
		}
	}
	return false
}

@(private)
statement_has_effects :: proc(b: ^Binder, id: ast.Node_ID) -> bool {
	#partial switch v in b.tree.nodes[id].variant {
	case ast.Bad,
	     ast.Empty,
	     ast.Function_Decl,
	     ast.Interface_Decl,
	     ast.Type_Alias_Decl,
	     ast.Import_Named,
	     ast.Import_Namespace,
	     ast.Export_Named:
		return false
	case ast.Var_Decl:
		for declarator_id in v.declarators {
			declarator := b.tree.nodes[declarator_id].variant.(ast.Declarator)
			if !is_inert(b, declarator.init) {
				return true
			}
		}
		return false
	}
	return true
}

// is_inert reports whether an expression only builds a value: it calls nothing, reads no other
// module and cannot fail. A name of this file or of the lib is inert to read; an imported one is
// not, since the module it comes from may not have run yet. `x!`, `x as T` and `a[i]` are not
// inert either: each of them is a check that ends the program when it does not hold (requirements
// 3.8), and a module that can fail while it loads runs code.
@(private)
is_inert :: proc(b: ^Binder, id: ast.Node_ID) -> bool {
	if id == ast.NO_NODE {
		return true
	}
	#partial switch v in b.tree.nodes[id].variant {
	case ast.Bad,
	     ast.Number_Literal,
	     ast.String_Literal,
	     ast.Bool_Literal,
	     ast.Null_Literal,
	     ast.Arrow:
		return true
	case ast.Ident:
		// A name of this file or of the lib holds its value already; an imported one may still be
		// waiting for the module it comes from.
		symbol := b.node_symbols[id]
		return symbol == NO_SYMBOL || !is_alias(b.symbols[symbol].kind)
	case ast.Member:
		return is_inert(b, v.object)
	case ast.Unary:
		return is_inert(b, v.operand)
	case ast.Binary:
		return is_inert(b, v.left) && is_inert(b, v.right)
	case ast.Conditional:
		return is_inert(b, v.condition) && is_inert(b, v.then_value) && is_inert(b, v.else_value)
	case ast.Template:
		return all_inert(b, v.expressions)
	case ast.Array_Literal:
		return all_inert(b, v.elements)
	case ast.Object_Literal:
		return all_inert(b, v.properties)
	case ast.Property:
		return is_inert(b, v.value)
	}
	return false
}

@(private)
all_inert :: proc(b: ^Binder, ids: []ast.Node_ID) -> bool {
	for id in ids {
		if !is_inert(b, id) {
			return false
		}
	}
	return true
}

// Diagnostics.

// report records a diagnostic about a name, at the name.
@(private)
report :: proc(b: ^Binder, code: diag.Code, name: ast.Name) {
	append(&b.diagnostics, diag.Diagnostic{code = code, span = name.span, args = {0 = name.text}})
}
