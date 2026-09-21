package check

import "../ast"
import "../program"
import "../source"

/*
The rules of requirements 2.2 and 2.3 that only check can decide. parse rejects every construct it
can see on its own, with a T2xxx code; what is left needs something parse does not have: the file a
declaration stands in, the name a member is read under, or the list of declarations the lib file
makes.

Three rules, each reported where the construct is written rather than where it is used, so one
mistake is one message however many times the name is read.
*/

// check_declaration_rules reports the two rules that hold for a declaration itself: `declare` is the
// lib file's alone, and so are type parameters.
@(private)
check_declaration_rules :: proc(c: ^Checker, id: ast.Node_ID) {
	if c.at.file == program.LIB {
		return // the lib file is where both are written; tests/check/lib_test.odin pins that
	}

	modifiers: ast.Modifiers
	type_params: []ast.Node_ID
	#partial switch v in c.at.tree.nodes[id].variant {
	case ast.Var_Decl:
		modifiers = v.modifiers
	case ast.Function_Decl:
		modifiers, type_params = v.modifiers, v.type_params
	case ast.Interface_Decl:
		modifiers, type_params = v.modifiers, v.type_params
	case ast.Type_Alias_Decl:
		modifiers, type_params = v.modifiers, v.type_params
	}

	if .Declare in modifiers {
		// The span starts at the first modifier, which is where the reader has to delete from.
		report(c, .Declare_Outside_Lib, span_of(c, id))
	}
	if len(type_params) > 0 {
		report(c, .Generic_Declaration, span_of(c, type_params[0]))
	}
}

// check_signature_type_params reports type parameters on a signature: a function type written out,
// or a method of an `interface`, which parse reads as the same node. `Array<T>` and `map<U>` are the
// lib file's, and resolve_type_params gives a type variable to no other file, so without this rule a
// user's `map<U>` would quietly mean `map<error>`.
@(private)
check_signature_type_params :: proc(c: ^Checker, type_params: []ast.Node_ID) {
	if len(type_params) == 0 || c.at.file == program.LIB {
		return
	}
	report(c, .Generic_Declaration, span_of(c, type_params[0]))
}

// check_member_name rejects the names of the prototype chain. Requirements 2.2 never supports
// prototypes: an object of tsnc is its fields and nothing behind them.
@(private)
check_member_name :: proc(c: ^Checker, name: ast.Name) -> (allowed: bool) {
	switch name.text {
	case "__proto__", "prototype":
		report(c, .Prototype_Access, name.span, name.text)
		return false
	}
	return true
}

// report_unknown_name gives `Symbol` a code of its own, so that it reads as a rule of the subset
// rather than as a name the reader forgot to import.
@(private)
report_unknown_name :: proc(c: ^Checker, name: string, span: source.Span) {
	if name == "Symbol" {
		report(c, .Symbol_Global, span)
		return
	}
	report(c, .Cannot_Find_Name, span, name)
}
