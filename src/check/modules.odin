package check

import "../ast"
import "../bind"
import "../source"

/*
Names that come from another module. bind gave every `import { a }` and `import * as m` a local alias
symbol and wrote down which request it came through; program turned each request into the File_ID it
named. check joins the two and follows the alias to the declaration it stands for, through any number
of re-exports.

Typed_File.node_symbols holds that declaration and not the local alias, so lower reads where a name
comes from instead of walking the import tables again.

Who reports what: driver reports a specifier that named no file, once, at the specifier. check_import
and check_export report a name the other module does not export, once, at the name, whether or not
the program ever uses it. Every use then resolves in silence, so ten uses of one bad import are one
message. What only a use can be wrong about it reports itself: a type used as a value, and a module
used as anything but the thing before a dot.

`import * as m` gives m no type of its own. Requirements 7 asks for the form, and the names behind it
resolve straight to their declarations, which is all a compiled program needs; a value that stood for
a whole module would have to be built in the heap at run time, with every function of that module
inside it. So `m.f` and `m.Point` work and a bare `m` is a mistake with a hint. Stricter than tsc,
which requirements 5 allows.
*/

// Import_Error is why an alias does not stand for what the use asked for. Each case says who has
// already reported it, or that the use has to.
@(private)
Import_Error :: enum u8 {
	None,
	No_Module, // the specifier named no file of the program: driver reported it
	Unknown_Export, // the module does not have the name at all: check_import reported it
	// The module has the name, but only as a type, or a `type` keyword stands in the way of the
	// value. The use reports it: an import list may legally name either half.
	Not_A_Value,
	Not_A_Type, // the module has the name, but only as a value. The use reports it
}

// Statements.

@(private)
check_import :: proc(c: ^Checker, id: ast.Node_ID, node: ast.Import_Named) {
	check_specifiers(c, id, node.specifiers)
}

// check_export skips an export list without `from`: it names this module's own declarations, and
// bind has already checked those.
@(private)
check_export :: proc(c: ^Checker, id: ast.Node_ID, node: ast.Export_Named) {
	if node.path == ast.NO_NODE {
		return
	}
	check_specifiers(c, id, node.specifiers)
}

// check_specifiers asks only whether the module has the name at all. Which half of a name a use
// needs is the use's question: a list may name a type, a value or both, and `import type` narrows
// what the uses may do rather than what may be named.
@(private)
check_specifiers :: proc(c: ^Checker, request: ast.Node_ID, specifiers: []ast.Node_ID) {
	module, ok := module_of_request(c, c.at.file, request)
	if !ok {
		return // driver has reported a specifier that named no file of the program
	}
	for id in specifiers {
		name := c.at.tree.nodes[id].variant.(ast.Specifier).name
		if _, err := exported_symbol(c, module, name.text, .Value); err != .Unknown_Export {
			continue
		}
		report(c, .Unknown_Export, name.span, name.text, request_specifier(c, c.at.file, request))
	}
}

// Uses.

// imported_name says nothing more about a failure the import statement already reported: the error
// type is assignable in both directions, so nothing cascades from it.
@(private)
imported_name :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	name: string,
	ref: Symbol_Ref,
) -> (
	declared, narrowed: Type_ID,
) {
	if c.program.bound[ref.file].symbols[ref.symbol].kind == .Namespace_Import {
		set_symbol(c, id, ref)
		report(c, .Namespace_As_Value, span_of(c, id), name)
		return ERROR, ERROR
	}

	target, err := resolved_import(c, ref, .Value)
	if err == .Not_A_Value {
		report(c, .Type_Used_As_Value, span_of(c, id), name)
		return ERROR, ERROR
	}
	if err != .None {
		return ERROR, ERROR
	}

	set_symbol(c, id, target)
	declared = type_of_symbol(c, target)
	return declared, narrow_reference(c, id, declared)
}

// namespace_of asks whether an expression is a name bound by `import * as`, which is the one shape
// that may stand before a dot without being a value. It only looks, and reports nothing.
@(private)
namespace_of :: proc(c: ^Checker, id: ast.Node_ID) -> (ref: Symbol_Ref, ok: bool) {
	node, is_ident := c.at.tree.nodes[id].variant.(ast.Ident)
	if !is_ident {
		return {}, false
	}
	named := resolve_name(c, id, node.name, .Value)
	if named.symbol == bind.NO_SYMBOL {
		return {}, false
	}
	if c.program.bound[named.file].symbols[named.symbol].kind != .Namespace_Import {
		return {}, false
	}
	return named, true
}

// namespace_member puts the export's own symbol into the tables, so `m.x` is a read of that
// declaration and not of a field of anything.
@(private)
namespace_member :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	node: ast.Member,
	ref: Symbol_Ref,
) -> (
	declared, narrowed: Type_ID,
) {
	set_symbol(c, node.object, ref)
	target, ok := namespace_export(c, ref, node.name, .Value)
	if !ok {
		return ERROR, ERROR
	}

	set_symbol(c, id, target)
	declared = type_of_symbol(c, target)
	return declared, narrow_reference(c, id, declared)
}

@(private)
namespace_type :: proc(
	c: ^Checker,
	id: ast.Node_ID,
	node: ast.Type_Ref,
	args: []Type_ID,
) -> Type_ID {
	ref := resolve_name(c, id, node.qualifier.text, .Value)
	if ref.symbol == bind.NO_SYMBOL {
		report_unknown_name(c, node.qualifier.text, node.qualifier.span)
		return ERROR
	}
	if c.program.bound[ref.file].symbols[ref.symbol].kind != .Namespace_Import {
		// bind resolves a qualifier as a value, and only `import * as m` makes a name that a type
		// may stand behind. parse rejects a deeper name, so there is nothing else this can be.
		report(c, .Namespace_As_Value, node.qualifier.span, node.qualifier.text)
		return ERROR
	}

	target, ok := namespace_export(c, ref, node.name, .Type)
	if !ok {
		return ERROR
	}
	set_symbol(c, id, target)
	return named_type(c, target, args, node.name)
}

// namespace_export reports a bad name itself: unlike a specifier, this is the only place the name
// is written.
@(private)
namespace_export :: proc(
	c: ^Checker,
	ref: Symbol_Ref,
	name: ast.Name,
	meaning: bind.Meaning,
) -> (
	target: Symbol_Ref,
	ok: bool,
) {
	module, request, has_module := module_of_alias(c, ref)
	if !has_module {
		return {}, false // driver has reported the module
	}

	found, err := exported_symbol(c, module, name.text, meaning)
	switch err {
	case .None:
		return found, true
	case .Not_A_Value:
		report(c, .Type_Used_As_Value, name.span, name.text)
	case .Not_A_Type:
		report_unknown_name(c, name.text, name.span)
	case .Unknown_Export:
		report(c, .Unknown_Export, name.span, name.text, request_specifier(c, ref.file, request))
	case .No_Module:
	// A module further along the chain named a file that is not there, and driver reported it.
	}
	return {}, false
}

// Resolution.

// resolved_import reports nothing: every caller knows which of its own spans a failure belongs on.
@(private)
resolved_import :: proc(
	c: ^Checker,
	ref: Symbol_Ref,
	meaning: bind.Meaning,
) -> (
	target: Symbol_Ref,
	err: Import_Error,
) {
	seen := make([dynamic]Symbol_Ref, 0, 4, context.temp_allocator)
	return follow_alias(c, ref, meaning, &seen)
}

@(private)
exported_symbol :: proc(
	c: ^Checker,
	module: source.File_ID,
	name: string,
	meaning: bind.Meaning,
) -> (
	target: Symbol_Ref,
	err: Import_Error,
) {
	seen := make([dynamic]Symbol_Ref, 0, 4, context.temp_allocator)
	return follow_export(c, module, name, meaning, &seen)
}

@(private)
follow_export :: proc(
	c: ^Checker,
	module: source.File_ID,
	name: string,
	meaning: bind.Meaning,
	seen: ^[dynamic]Symbol_Ref,
) -> (
	target: Symbol_Ref,
	err: Import_Error,
) {
	entry, found := bind.lookup_export(c.program.bound[module], name, meaning)
	if !found || entry.symbol == bind.NO_SYMBOL {
		return {}, missing_meaning(c, module, name, meaning)
	}

	ref := Symbol_Ref {
		file   = module,
		symbol = entry.symbol,
	}
	if !bind.is_alias(c.program.bound[module].symbols[entry.symbol].kind) {
		return ref, .None
	}
	return follow_alias(c, ref, meaning, seen)
}

// missing_meaning tells a name the module does not have at all from a name it has in the other half
// only. The difference decides who reports it: an import list may name either half, so a name that is
// there is the list's business no more, and the use that asked for the wrong half says so itself.
@(private)
missing_meaning :: proc(
	c: ^Checker,
	module: source.File_ID,
	name: string,
	meaning: bind.Meaning,
) -> Import_Error {
	other: bind.Meaning = .Type if meaning == .Value else .Value
	entry, found := bind.lookup_export(c.program.bound[module], name, other)
	if !found || entry.symbol == bind.NO_SYMBOL {
		return .Unknown_Export
	}
	return .Not_A_Value if meaning == .Value else .Not_A_Type
}

// follow_alias keeps in seen the aliases the walk has been through: modules that re-export each
// other in a ring declare the name nowhere, so the walk answers that the name is not exported
// rather than going round again.
@(private)
follow_alias :: proc(
	c: ^Checker,
	ref: Symbol_Ref,
	meaning: bind.Meaning,
	seen: ^[dynamic]Symbol_Ref,
) -> (
	target: Symbol_Ref,
	err: Import_Error,
) {
	for visited in seen {
		if visited == ref {
			return {}, .Unknown_Export
		}
	}
	append(seen, ref)

	record, has_record := bind.import_of(c.program.bound[ref.file], ref.symbol)
	if !has_record || record.name.text == "" {
		// bind records an import for every alias, and one with no name is `import * as m`, which
		// stands for a whole module rather than for a name in it.
		return {}, .Unknown_Export
	}
	if record.type_only && meaning == .Value {
		// `import type` and `export type` are erased, so the module behind them never runs and there
		// is no value to take, whatever the other module declares.
		return {}, .Not_A_Value
	}

	module, has_module := module_of_request(c, ref.file, record.request)
	if !has_module {
		return {}, .No_Module
	}
	return follow_export(c, module, record.name.text, meaning, seen)
}

// The module graph.

// module_of_request fails only for a request driver has already reported: program drew an edge for
// every request it could resolve.
@(private)
module_of_request :: proc(
	c: ^Checker,
	file: source.File_ID,
	request: ast.Node_ID,
) -> (
	module: source.File_ID,
	ok: bool,
) {
	for edge in c.program.imports[file] {
		if edge.request == request {
			return edge.module, true
		}
	}
	return 0, false
}

@(private)
module_of_alias :: proc(
	c: ^Checker,
	ref: Symbol_Ref,
) -> (
	module: source.File_ID,
	request: ast.Node_ID,
	ok: bool,
) {
	record, has_record := bind.import_of(c.program.bound[ref.file], ref.symbol)
	if !has_record {
		return 0, ast.NO_NODE, false
	}
	module, ok = module_of_request(c, ref.file, record.request)
	return module, record.request, ok
}

// request_specifier is the path of an import or a re-export as the source wrote it, which is how a
// message about that module names it.
@(private)
request_specifier :: proc(c: ^Checker, file: source.File_ID, request: ast.Node_ID) -> string {
	tree := &c.program.trees[file]
	path := ast.NO_NODE
	#partial switch v in tree.nodes[request].variant {
	case ast.Import_Named:
		path = v.path
	case ast.Import_Namespace:
		path = v.path
	case ast.Export_Named:
		path = v.path
	}
	if path == ast.NO_NODE {
		return ""
	}
	literal, is_literal := tree.nodes[path].variant.(ast.String_Literal)
	return literal.value if is_literal else ""
}
