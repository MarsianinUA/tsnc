/*
The names of one file: symbols, scopes, the flow graph that check narrows with, the import and
export tables and the top-level side effects flag. parse builds the tree, bind_file reads it once
and returns a frozen Bound_File; check and lower read that and never change it.

Tables:
- symbols, scopes and flow hold the file's own data. Entry zero of each is the one that means
  nothing: symbols[NO_SYMBOL] is a placeholder, scopes[MODULE_SCOPE] is the module's own scope,
  which only ast.ROOT opens, and flow[UNREACHABLE] is the unreachable node. A fact that says
  nothing therefore reads as zero, as ast.NO_NODE does.
- node_symbols, node_scopes and node_flow are as long as tree.nodes and hold a fact of a node by
  its ast.Node_ID.
- imports, exports and has_side_effects describe the file as a module. Only top-level statements
  feed them.

Names:
- A declaration puts a Symbol into the scope it belongs to; a use of the name (an ast.Ident for a
  value, an ast.Type_Ref for a type) records that symbol in node_symbols. A name a scope does not
  hold stays NO_SYMBOL: it is a lib name (`console`, `Array`, `undefined`) or unknown, and check
  decides which.
- A name has one value meaning and one type meaning, so an `interface` and a `const` of one name
  are two symbols, as the lib file's `Math` is. A second declaration of a meaning that is taken is
  reported; two interfaces of one name do not merge.
- The lib file is an ordinary file here. Its module scope holds the names check looks up when a
  file of its own does not declare them.

Flow graph: a node per point where control joins, branches or writes a variable, in the style of
the tsc binder, with the antecedent pointing backwards. check walks it from a reference (an
ast.Ident, ast.Member or ast.Index, whose flow node node_flow holds) towards Flow_Start and narrows
by the conditions and assignments on the way. The graph of a function stands on its own: it starts
at Flow_Start, and only an arrow keeps the flow where it was created, so that narrowing carries
into it.

Where tsnc differs from tsc: a condition that narrows nothing still gets a node; the left side of
`??` is asked whether it is null or undefined, where tsc asks whether it is truthy; the flow of an
immediately called arrow is not inlined; the growth of an array of unknown element type is not
tracked, so check asks for an annotation; Assigned covers the whole file instead of a point in it.

Memory: every table of the result, and the diagnostics, come from the allocator passed in, which is
meant to be an arena: bind never frees. Names and texts are borrowed from the tree, so the result
must not outlive it. Scratch data goes to context.temp_allocator.
*/
package bind

import "base:runtime"
import "core:slice"

import "../ast"
import "../diag"

// Symbol_ID indexes Bound_File.symbols.
Symbol_ID :: distinct u32

// NO_SYMBOL is the name that no declaration of this file holds.
NO_SYMBOL :: Symbol_ID(0)

// Scope_ID indexes Bound_File.scopes.
Scope_ID :: distinct u32

// MODULE_SCOPE is the file's own scope, opened by ast.ROOT. Its symbols are the module's globals.
MODULE_SCOPE :: Scope_ID(0)

// Flow_ID indexes Bound_File.flow.
Flow_ID :: distinct u32

// UNREACHABLE is the flow of code no path reaches.
UNREACHABLE :: Flow_ID(0)

Bound_File :: struct {
	symbols:          []Symbol,
	scopes:           []Scope, // scopes[MODULE_SCOPE] first, then in the order they open
	flow:             []Flow_Node,
	// The facts of a node, indexed by ast.Node_ID; each is as long as tree.nodes.
	// A declaring node holds the symbol it declares, an ast.Ident or ast.Type_Ref the symbol it
	// names.
	node_symbols:     []Symbol_ID,
	// The scope a node opens, and the function scope for the body ast.Block of a function, whose
	// names belong to the function. Every other node reads MODULE_SCOPE, which says nothing.
	node_scopes:      []Scope_ID,
	// An ast.Ident, ast.Member or ast.Index holds the flow before the value is read; the body
	// ast.Block of a function holds the flow at its end.
	node_flow:        []Flow_ID,
	// A node that names a value of this file, an ast.Ident or the qualifier of an ast.Type_Ref,
	// holds the outermost function scope between it and the scope that declares the name: code that
	// may run later than where it stands, so before or after the declaration. MODULE_SCOPE when
	// there is none, and for every other node.
	node_deferred:    []Scope_ID,
	imports:          []Import, // in symbol order
	exports:          []Export, // in source order
	has_side_effects: bool,
}

Symbol :: struct {
	name:        ast.Name,
	kind:        Symbol_Kind,
	flags:       Symbol_Flags,
	// The scope that holds the symbol. MODULE_SCOPE means a module global; the alias of a
	// re-export names MODULE_SCOPE too, but no scope lists it, since it is not visible in the file.
	scope:       Scope_ID,
	// ast.Declarator, Function_Decl, Param, Type_Param, Interface_Decl, Type_Alias_Decl,
	// Specifier or Import_Namespace.
	declaration: ast.Node_ID,
}

// Symbol_Kind decides what a name means: see meanings.
Symbol_Kind :: enum u8 {
	Let,
	Const,
	Function,
	Param,
	Interface,
	Type_Alias,
	Type_Param,
	Import, // `import { a }`, `import { a as b }` or a re-exported name; see Bound_File.imports
	Namespace_Import, // `import * as m`
}

Symbol_Flag :: enum u8 {
	// The symbol is the target of an assignment or of `++` or `--` somewhere in the file. A
	// captured symbol without it never changes after its declaration, so lower may copy it.
	Assigned,
	// The symbol is used inside a function other than the one that declares it. Module globals
	// never carry it: they are cells of the program, not of an environment.
	Captured,
}

Symbol_Flags :: bit_set[Symbol_Flag;u8]

// Meaning is the half of a name a use asks for: `let x` declares the value `x`, `interface x` the
// type `x`.
Meaning :: enum u8 {
	Value,
	Type,
}

Meanings :: bit_set[Meaning;u8]

Scope :: struct {
	kind:     Scope_Kind,
	parent:   Scope_ID, // MODULE_SCOPE is its own parent; stop the walk at kind .Module
	node:     ast.Node_ID, // the node that opens the scope
	symbols:  []Symbol_ID, // declared here, in source order
	// A .Function scope: the symbols of an enclosing function that the code inside uses, in the
	// order they are first used. They are what lower puts into the closure's environment.
	captures: []Symbol_ID,
}

Scope_Kind :: enum u8 {
	Module, // ast.ROOT
	Function, // ast.Function_Decl, ast.Arrow: type parameters, parameters and the body's names
	Block, // ast.Block, ast.For, ast.For_Of, ast.Switch
	Type, // ast.Interface_Decl, ast.Type_Alias_Decl, ast.Function_Type: their type parameters
}

// Import is what an alias symbol stands for: a name of another module, named by the request. The
// request is an ast.Import_Named, ast.Import_Namespace or ast.Export_Named node, one of
// ast.File_AST.imports, and driver resolves its path to a file.
Import :: struct {
	symbol:    Symbol_ID,
	name:      ast.Name, // the name the other module exports; empty for `import * as m`
	request:   ast.Node_ID,
	type_only: bool, // `import type { A }` or `import { type A }`: a type, never a value
}

// Export.symbol is the local symbol, or the alias of a re-export, and NO_SYMBOL when the module
// declares no such name, which bind reports.
Export :: struct {
	name:      ast.Name, // the name under which the module exports it
	symbol:    Symbol_ID,
	type_only: bool, // `export type { A }` or `export { type A }`
}

// Flow_Node variants all point backwards, to the flow they follow, except Flow_Start and
// Flow_Unreachable.
Flow_Node :: union #no_nil {
	Flow_Unreachable,
	Flow_Start,
	Flow_Branch,
	Flow_Loop,
	Flow_Assignment,
	Flow_Condition,
	Flow_Switch_Clause,
	Flow_Call,
}

// Flow_Unreachable is flow[UNREACHABLE] and nothing else.
Flow_Unreachable :: struct {}

Flow_Start :: struct {
	function: ast.Node_ID, // ast.Function_Decl, ast.Arrow, or ast.ROOT for the module
	// Where an arrow is created, so that check keeps a narrowing inside it. UNREACHABLE for a
	// function declaration, which is hoisted, and for the module.
	outer:    Flow_ID,
}

// Flow_Branch is where paths join: after an `if`, a `switch` or a logical operator.
Flow_Branch :: struct {
	antecedents: []Flow_ID,
}

// Flow_Loop.antecedents[0] is the path that enters the loop; the rest come back from the body.
Flow_Loop :: struct {
	antecedents: []Flow_ID,
}

// Flow_Assignment is a write to a variable, a field or an element.
Flow_Assignment :: struct {
	// ast.Declarator with an initializer, ast.Assign, ast.Update, or the ast.For_Of whose loop
	// variable takes the next element.
	node:       ast.Node_ID,
	antecedent: Flow_ID,
}

Flow_Condition :: struct {
	condition:   ast.Node_ID,
	kind:        Condition_Kind,
	assume_true: bool,
	antecedent:  Flow_ID,
}

Condition_Kind :: enum u8 {
	Truthy, // `if`, `while`, `&&`, `||`, `?:`, `!`, the value a tested `??` keeps: it is truthy
	Not_Nullish, // the left side of `??` and `??=`: the value is neither null nor undefined
}

// Flow_Switch_Clause is the path from the head of a `switch` to the cases [clause_start,
// clause_end). An empty range is the path taken when no case matched and there is no `default`.
Flow_Switch_Clause :: struct {
	statement:    ast.Node_ID, // the ast.Switch
	clause_start: u32,
	clause_end:   u32,
	antecedent:   Flow_ID,
}

// Flow_Call is a call statement on a name or a field, such as `process.exit(1)`. check stops here
// when the callee returns `never`.
Flow_Call :: struct {
	call:       ast.Node_ID,
	antecedent: Flow_ID,
}

// meanings answers both for an alias, until check follows it into the other module.
meanings :: proc(kind: Symbol_Kind) -> Meanings {
	switch kind {
	case .Let, .Const, .Function, .Param:
		return {.Value}
	case .Interface, .Type_Alias, .Type_Param:
		return {.Type}
	case .Import, .Namespace_Import:
		return {.Value, .Type}
	}
	return {}
}

// is_alias marks the symbols check follows through Bound_File.imports.
is_alias :: proc(kind: Symbol_Kind) -> bool {
	return kind == .Import || kind == .Namespace_Import
}

// bind_file reports every problem it sees and always returns a whole result. Everything the result
// holds comes from allocator; the texts stay borrowed from the tree, which must outlive it.
bind_file :: proc(
	tree: ^ast.File_AST,
	allocator := context.allocator,
) -> (
	bound: Bound_File,
	diagnostics: []diag.Diagnostic,
) {
	module, is_module := tree.nodes[ast.ROOT].variant.(ast.Module)
	ensure(is_module, "the root of a File_AST is its Module")

	b := Binder {
		tree            = tree,
		allocator       = allocator,
		symbols         = make([dynamic]Symbol, 1, 16, allocator),
		scopes          = make([dynamic]Scope_Build, 0, 8, context.temp_allocator),
		flow            = make([dynamic]Flow_Node, 1, 16, allocator),
		labels          = make([dynamic]Label, 0, 8, context.temp_allocator),
		node_symbols    = make([]Symbol_ID, len(tree.nodes), allocator),
		node_scopes     = make([]Scope_ID, len(tree.nodes), allocator),
		node_flow       = make([]Flow_ID, len(tree.nodes), allocator),
		node_deferred   = make([]Scope_ID, len(tree.nodes), allocator),
		imports         = make([dynamic]Import, allocator),
		exports         = make([dynamic]Export, allocator),
		diagnostics     = make([dynamic]diag.Diagnostic, allocator),
		break_target    = NO_LABEL,
		continue_target = NO_LABEL,
	}
	defer free_scratch(&b)
	b.flow[UNREACHABLE] = Flow_Unreachable{}

	open_scope(&b, .Module, ast.ROOT) // MODULE_SCOPE, its own parent
	b.function = MODULE_SCOPE
	b.current = add_flow(&b, Flow_Start{function = ast.ROOT})

	declare_statements(&b, module.statements)
	bind_statements(&b, module.statements)
	collect_exports(&b, module.statements)
	b.has_side_effects = module_has_effects(&b, module.statements)

	return freeze(&b), b.diagnostics[:]
}

// lookup looks in the one scope: check reads the lib file's MODULE_SCOPE with it, since a name no
// file declares is a lib name.
lookup :: proc(bound: Bound_File, scope: Scope_ID, name: string, meaning: Meaning) -> Symbol_ID {
	for id in bound.scopes[scope].symbols {
		symbol := bound.symbols[id]
		if symbol.name.text == name && meaning in meanings(symbol.kind) {
			return id
		}
	}
	return NO_SYMBOL
}

lookup_export :: proc(
	bound: Bound_File,
	name: string,
	meaning: Meaning,
) -> (
	entry: Export,
	ok: bool,
) {
	for export in bound.exports {
		if export.name.text == name && meaning in export_meanings(bound.symbols, export) {
			return export, true
		}
	}
	return {}, false
}

import_of :: proc(bound: Bound_File, symbol: Symbol_ID) -> (record: Import, ok: bool) {
	for entry in bound.imports {
		if entry.symbol == symbol {
			return entry, true
		}
	}
	return {}, false
}

@(private)
export_meanings :: proc(symbols: []Symbol, entry: Export) -> Meanings {
	if entry.type_only {
		return {.Type}
	}
	if entry.symbol == NO_SYMBOL {
		return {.Value, .Type}
	}
	return meanings(symbols[entry.symbol].kind)
}

@(private)
Binder :: struct {
	tree:             ^ast.File_AST,
	allocator:        runtime.Allocator,
	symbols:          [dynamic]Symbol,
	scopes:           [dynamic]Scope_Build,
	flow:             [dynamic]Flow_Node,
	labels:           [dynamic]Label,
	node_symbols:     []Symbol_ID,
	node_scopes:      []Scope_ID,
	node_flow:        []Flow_ID,
	node_deferred:    []Scope_ID,
	imports:          [dynamic]Import,
	exports:          [dynamic]Export,
	diagnostics:      [dynamic]diag.Diagnostic,
	scope:            Scope_ID, // the innermost open scope
	function:         Scope_ID, // the innermost .Function scope, or MODULE_SCOPE
	current:          Flow_ID, // the flow at the point being bound
	break_target:     Label_ID, // where `break` goes, NO_LABEL outside a loop and a switch
	continue_target:  Label_ID,
	// Whether an assignment has been bound since the flag was cleared. A conditional expression
	// whose sides changed nothing keeps the flow it started from.
	has_flow_effects: bool,
	has_side_effects: bool,
}

// free_scratch matters only to an allocator that frees, such as the tracking allocator of the
// tests: the temporary allocator of an arena keeps its pages until its owner resets them. freeze
// has already copied the scopes and labels into the result.
@(private)
free_scratch :: proc(b: ^Binder) {
	for &scope in b.scopes {
		delete(scope.symbols)
		delete(scope.captures)
		delete(scope.names)
	}
	delete(b.scopes)
	for &label in b.labels {
		delete(label.antecedents)
	}
	delete(b.labels)
}

@(private)
freeze :: proc(b: ^Binder) -> Bound_File {
	scopes := make([]Scope, len(b.scopes), b.allocator)
	for build, i in b.scopes {
		scopes[i] = Scope {
			kind     = build.kind,
			parent   = build.parent,
			node     = build.node,
			symbols  = slice.clone(build.symbols[:], b.allocator),
			captures = slice.clone(build.captures[:], b.allocator),
		}
	}
	for label in b.labels {
		if label.flow == UNREACHABLE {
			continue // a label that led nowhere, or a branch that collapsed into its one path
		}
		antecedents := slice.clone(label.antecedents[:], b.allocator)
		#partial switch &node in b.flow[label.flow] {
		case Flow_Branch:
			node.antecedents = antecedents
		case Flow_Loop:
			node.antecedents = antecedents
		case:
			unreachable()
		}
	}
	return {
		symbols = b.symbols[:],
		scopes = scopes,
		flow = b.flow[:],
		node_symbols = b.node_symbols,
		node_scopes = b.node_scopes,
		node_flow = b.node_flow,
		node_deferred = b.node_deferred,
		imports = b.imports[:],
		exports = b.exports[:],
		has_side_effects = b.has_side_effects,
	}
}
