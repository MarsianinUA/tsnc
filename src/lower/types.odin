package lower

import "../check"
import "../ir"

/*
The one place a TypeScript type becomes an IR type. check owns the first world and ir the second,
and requirements 3.1 to 3.4 fix the map between them: a number is an f64, a boolean a machine
boolean, a string a reference to a cell, and anything that can hold more than one shape at run time
is the two-word tagged value.

A type this slice cannot represent answers `false`, and the caller reports Not_Lowered rather than
guessing. Objects, arrays and function values are the whole of that list, and milestone 5 removes it.
*/

// ir_type is the IR type a value of this TypeScript type lives in.
ir_type :: proc(types: []check.Type, id: check.Type_ID) -> (type: ir.Type, ok: bool) {
	switch v in types[id] {
	case check.Basic_Kind:
		switch v {
		case .Number:
			return ir.F64, true
		case .Boolean:
			return ir.BOOL, true
		case .String:
			return ir.STR, true
		case .Null, .Undefined, .Any, .Unknown:
			return ir.TAGGED, true
		case .Void:
			return ir.VOID, true
		case .Never:
			// The result of a call that does not come back, such as process.exit. Nothing reads it.
			return ir.VOID, true
		case .Error:
			return ir.VOID, false
		}
	case check.Literal:
		switch _ in v.value {
		case f64:
			return ir.F64, true
		case string:
			return ir.STR, true
		case bool:
			return ir.BOOL, true
		}
	case check.Union:
		// A union whose members all live in one representation is that representation: `2 | 3` is
		// the type of `c ? 2 : 3` and is a plain number at run time. Only a union that can hold
		// more than one shape needs the tag of requirements 3.4. Unions are canonical and never
		// nested, so this looks one level down and no further.
		first := ir_type(types, v.members[0]) or_return
		for other in v.members[1:] {
			member := ir_type(types, other) or_return
			if member != first {
				return ir.TAGGED, true
			}
		}
		return first, true
	case check.Object, check.Array, check.Function, check.Type_Var, check.Overload:
		return ir.VOID, false
	}
	return ir.VOID, false
}

// construct_text names what a type belongs to, for the Not_Lowered message. A union answers for the
// first member that has no representation, since that member is why the union has none either.
construct_text :: proc(types: []check.Type, id: check.Type_ID) -> string {
	#partial switch v in types[id] {
	case check.Object:
		return "objects"
	case check.Array:
		return "arrays"
	case check.Function:
		return "function values"
	case check.Union:
		for member in v.members {
			if _, ok := ir_type(types, member); !ok {
				return construct_text(types, member)
			}
		}
	}
	return "values of this type"
}
