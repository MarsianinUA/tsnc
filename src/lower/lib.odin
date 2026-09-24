package lower

import "../abi"
import "../ir"

/*
One row per name of src/lib/lib.d.ts, saying what the compiler emits for it. The lib file is the
only description of the standard library, and this table is the other half of it: a name declared
there and missing here would type and then compile into nothing, so tests/lower checks the two
against each other in both directions.

Where a name goes follows requirements 4.5. Math is not a runtime call: core LLVM already has the
f64 intrinsics, and a wrapper around a wrapper would stop constant folding and inlining, so the code
generator emits the intrinsic or a call to libm. Only what C does differently goes to the runtime:
round takes a half toward positive infinity, and max and min have their own rules for NaN and the
two zeros. What holds a reference to a TS value, or needs the GC heap, is a runtime call as well,
apart from the length of a string or an array, which is one load, and map, filter, forEach and
reduce, which are loops lower builds around the callback it inlines.

Later is the answer for four Math names, each with its reason in the row: the instruction set has
no way to say them yet.
*/

// Owner says which half of a name the row is keyed by: `Math.floor` names a value the lib declares,
// `x.toFixed` names a method of the interface that types a primitive or an array.
Owner :: enum u8 {
	Value,
	Instance,
}

// Later is a name of the v1 language this build does not compile yet. construct is what the
// Not_Lowered message puts in place of {0}.
Later :: struct {
	construct: string,
}

Constant :: struct {
	value: f64,
}

Intrinsic :: struct {
	op: ir.Intrinsic_Op,
}

// Operator is a name the IR already has an arithmetic instruction for: Math.pow is exponentiation,
// whose corners differ from libm's pow.
Operator :: struct {
	op: ir.Binary_Op,
}

// Runtime is a call with the arity abi.RUNTIME_EXPORTS gives the export, each argument in the C type
// its row declares.
Runtime :: struct {
	export: abi.Runtime_Proc,
}

// Method is a runtime call whose first argument is the receiver: the string, number or array in
// front of the dot. missing holds, for the arguments after it, the number the specification treats
// exactly as undefined, which one the call leaves out takes (abi.MISSING_END and its kin).
Method :: struct {
	export:  abi.Runtime_Proc,
	missing: [2]f64,
}

// Fold is a name that takes any number of numbers and folds them two at a time, left to right.
// empty is its answer for a call with no arguments at all.
Fold :: struct {
	export: abi.Runtime_Proc,
	empty:  f64,
}

// Builtin is a name lower builds out of other instructions rather than calling anything for.
Builtin :: enum u8 {
	Console_Log,
	Console_Error,
	Process_Argv,
	Process_Exit,
	Number_Is_Integer,
	Math_Sign,
	Length,
	String_Of,
	String_Includes,
	Array_Push,
	Array_Join,
	Array_Sort,
	Array_Map,
	Array_Filter,
	Array_For_Each,
	Array_Reduce,
}

Strategy :: union #no_nil {
	Later,
	Constant,
	Intrinsic,
	Operator,
	Runtime,
	Method,
	Fold,
	Builtin,
}

Lib_Entry :: struct {
	owner:    Owner,
	root:     string, // the declared name, or the interface of a primitive
	member:   string, // empty when the declared name is the whole of it
	strategy: Strategy,
}

// LIB_STRATEGIES is read by key and never iterated into the output, so its order is free; it
// follows src/lib/lib.d.ts to make the two easy to compare by eye. The values of the Math constants
// are the shortest decimal that reads back as the double, which is the form Node prints.
@(rodata)
LIB_STRATEGIES := []Lib_Entry {
	{.Value, "console", "log", Builtin.Console_Log},
	{.Value, "console", "error", Builtin.Console_Error},
	{.Value, "process", "argv", Builtin.Process_Argv},
	{.Value, "process", "exit", Builtin.Process_Exit},
	{.Value, "NaN", "", Constant{NAN}},
	{.Value, "Infinity", "", Constant{INFINITY}},
	{.Value, "Math", "E", Constant{2.718281828459045}},
	{.Value, "Math", "LN10", Constant{2.302585092994046}},
	{.Value, "Math", "LN2", Constant{0.6931471805599453}},
	{.Value, "Math", "LOG2E", Constant{1.4426950408889634}},
	{.Value, "Math", "LOG10E", Constant{0.4342944819032518}},
	{.Value, "Math", "PI", Constant{3.141592653589793}},
	{.Value, "Math", "SQRT1_2", Constant{0.7071067811865476}},
	{.Value, "Math", "SQRT2", Constant{1.4142135623730951}},
	{.Value, "Math", "abs", Intrinsic{.Abs}},
	{.Value, "Math", "acos", Intrinsic{.Acos}},
	{.Value, "Math", "acosh", Intrinsic{.Acosh}},
	{.Value, "Math", "asin", Intrinsic{.Asin}},
	{.Value, "Math", "asinh", Intrinsic{.Asinh}},
	{.Value, "Math", "atan", Intrinsic{.Atan}},
	{.Value, "Math", "atan2", Intrinsic{.Atan2}},
	{.Value, "Math", "atanh", Intrinsic{.Atanh}},
	{.Value, "Math", "cbrt", Intrinsic{.Cbrt}},
	{.Value, "Math", "ceil", Intrinsic{.Ceil}},
	// Counting leading zeros is an operation on a 32-bit integer, and the IR has no integer type
	// before v2 narrows one out of f64.
	{.Value, "Math", "clz32", Later{"`Math.clz32`"}},
	{.Value, "Math", "cos", Intrinsic{.Cos}},
	{.Value, "Math", "cosh", Intrinsic{.Cosh}},
	{.Value, "Math", "exp", Intrinsic{.Exp}},
	{.Value, "Math", "expm1", Intrinsic{.Expm1}},
	{.Value, "Math", "floor", Intrinsic{.Floor}},
	// Rounding to the nearest f32 and back needs the two conversions, which the IR has no
	// instruction for.
	{.Value, "Math", "fround", Later{"`Math.fround`"}},
	// Scaling a sum of squares over any number of arguments is not a fold of a two-argument
	// function: folding one would answer a different last digit than Node does.
	{.Value, "Math", "hypot", Later{"`Math.hypot`"}},
	// A 32-bit product wraps, and an f64 multiply of two 32-bit values loses the low bits it has
	// to keep.
	{.Value, "Math", "imul", Later{"`Math.imul`"}},
	{.Value, "Math", "log", Intrinsic{.Log}},
	{.Value, "Math", "log10", Intrinsic{.Log10}},
	{.Value, "Math", "log1p", Intrinsic{.Log1p}},
	{.Value, "Math", "log2", Intrinsic{.Log2}},
	{.Value, "Math", "max", Fold{.Math_Max, NEG_INFINITY}},
	{.Value, "Math", "min", Fold{.Math_Min, INFINITY}},
	{.Value, "Math", "pow", Operator{.Power}},
	{.Value, "Math", "round", Runtime{.Math_Round}},
	{.Value, "Math", "sign", Builtin.Math_Sign},
	{.Value, "Math", "sin", Intrinsic{.Sin}},
	{.Value, "Math", "sinh", Intrinsic{.Sinh}},
	{.Value, "Math", "sqrt", Intrinsic{.Sqrt}},
	{.Value, "Math", "tan", Intrinsic{.Tan}},
	{.Value, "Math", "tanh", Intrinsic{.Tanh}},
	{.Value, "Math", "trunc", Intrinsic{.Trunc}},
	{.Value, "Number", "isInteger", Builtin.Number_Is_Integer},
	{.Value, "Number", "parseFloat", Runtime{.Number_Parse_Float}},
	{.Value, "String", "", Builtin.String_Of},
	{.Instance, "Number", "toString", Method{.Number_To_String, {}}},
	{.Instance, "Number", "toFixed", Method{.Number_To_Fixed, {0, 0}}},
	{.Instance, "String", "length", Builtin.Length},
	{.Instance, "String", "charCodeAt", Method{.String_Char_Code_At, {0, 0}}},
	{.Instance, "String", "slice", Method{.String_Slice, {0, abi.MISSING_END}}},
	{.Instance, "String", "indexOf", Method{.String_Index_Of, {0, 0}}},
	{.Instance, "String", "includes", Builtin.String_Includes},
	{.Instance, "String", "split", Method{.String_Split, {0, abi.MISSING_LIMIT}}},
	{.Instance, "String", "trim", Method{.String_Trim, {}}},
	{.Instance, "String", "toUpperCase", Method{.String_To_Upper, {}}},
	{.Instance, "String", "toLowerCase", Method{.String_To_Lower, {}}},
	{.Instance, "String", "startsWith", Method{.String_Starts_With, {0, 0}}},
	{.Instance, "String", "endsWith", Method{.String_Ends_With, {0, abi.MISSING_END}}},
	{.Instance, "Array", "length", Builtin.Length},
	{.Instance, "Array", "push", Builtin.Array_Push},
	{.Instance, "Array", "pop", Method{.Array_Pop, {}}},
	{.Instance, "Array", "indexOf", Method{.Array_Index_Of, {0, 0}}},
	{.Instance, "Array", "includes", Method{.Array_Includes, {0, 0}}},
	{.Instance, "Array", "slice", Method{.Array_Slice, {0, abi.MISSING_END}}},
	{.Instance, "Array", "join", Builtin.Array_Join},
	{.Instance, "Array", "sort", Builtin.Array_Sort},
	{.Instance, "Array", "map", Builtin.Array_Map},
	{.Instance, "Array", "filter", Builtin.Array_Filter},
	{.Instance, "Array", "forEach", Builtin.Array_For_Each},
	{.Instance, "Array", "reduce", Builtin.Array_Reduce},
}

// The two values a program can name without writing digits. ECMAScript leaves the payload of NaN
// free; this is the quiet NaN every engine produces.
NAN :: f64(0h7FF8_0000_0000_0000)
INFINITY :: f64(0h7FF0_0000_0000_0000)
NEG_INFINITY :: f64(0hFFF0_0000_0000_0000)

lib_strategy :: proc(owner: Owner, root, member: string) -> (Strategy, bool) {
	for entry in LIB_STRATEGIES {
		if entry.owner == owner && entry.root == root && entry.member == member {
			return entry.strategy, true
		}
	}
	return Later{""}, false
}

// instance_owner is the interface whose methods a value of this IR type has. Only a primitive and
// an array have one, which is what makes the table's Instance half small.
instance_owner :: proc(low: ^Lowering, type: ir.Type) -> (string, bool) {
	#partial switch type.kind {
	case .F64:
		return "Number", true
	case .Str:
		return "String", true
	case .Ref:
		if low.builder.layouts[type.layout].kind == .Array {
			return "Array", true
		}
	}
	return "", false
}

// construct_of names a strategy for the Not_Lowered message: what the row itself says, or the
// member, for a strategy that turned out not to fit where it was used.
construct_of :: proc(strategy: Strategy, name: string) -> string {
	if later, is_later := strategy.(Later); is_later {
		return later.construct
	}
	return name
}
