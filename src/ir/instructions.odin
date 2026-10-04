package ir

import "core:math"

import "../abi"
import "../source"

// Instruction carries the span it came from: a failure of the runtime names a place in the source,
// the dump of -emit-ir points at one, and v2 builds debug information out of them.
Instruction :: struct {
	span:    source.Span,
	type:    Type, // VOID when the instruction defines no value
	variant: Variant,
}

// Incoming is one edge of a phi: the value that arrives when control came through that block.
Incoming :: struct {
	block: Block_ID,
	value: Value_ID,
}

// Variant is #no_nil with Unreachable first, so a zero Instruction is an inert terminator rather
// than an empty union, the way ast.Variant is #no_nil with Bad first.
//
// The set is closed: codegen is one exhaustive switch over it and knows nothing else about the
// program. A new case is a change to codegen as well.
Variant :: union #no_nil {
	Unreachable,

	// Values.
	Param,
	Const_Number,
	Const_Bool,
	Const_Undefined,
	Const_Null,
	Const_String,
	Binary,
	Unary,
	Compare,
	Phi,
	Convert,

	// Heap cells. A field index reads the layout of the Ref type of the cell operand.
	Alloc,
	New_Array,
	Field_Load,
	Field_Store,
	Field_Store_Ref,
	Length,
	Reserve,
	Set_Length,
	Bounds_Check,
	Element_Load,
	Element_Store,
	Element_Store_Ref,
	Unit_Load,
	Ascii_Cell,
	Layout_Test,
	Null_Test,
	Non_Null,
	As_Layout,
	Same_Cell,

	// Tagged values.
	Tag_Test,
	Box,
	Unbox,

	// Module bindings.
	Global_Load,
	Global_Store,

	// Function values.
	Env,
	Func_Ref,
	Make_Closure,

	// Calls.
	Call,
	Call_Closure,
	Call_Runtime,
	Intrinsic,

	// Terminators.
	Jump,
	Branch,
	Return,
	Fail,
}

// Param is the value of a TS parameter. begin_func emits one per entry of Func.params, in order, so
// parameter i is Value_ID(i). An environment is not a Param but an Env: it arrives ahead of them
// all.
Param :: struct {
	index: i32,
}

Const_Number :: struct {
	value: f64,
}

Const_Bool :: struct {
	value: bool,
}

// Const_Undefined is Tagged: it has no type of its own to live in.
Const_Undefined :: struct {}

// Const_Null is Tagged, or a reference type: typed as a Ref or a Closure it is the null reference,
// the zero of a binding that holds an object or a function; typed as a reference that may hold null,
// it is that null or undefined. A present string binding holds it only as the mark of a declaration
// that has not run (Null_Test); the zero of a string is the empty cell.
Const_Null :: struct {}

// Const_String is a Str pointing at a cell codegen puts in read-only data.
Const_String :: struct {
	text: String_ID,
}

Binary :: struct {
	op:    Binary_Op,
	left:  Value_ID,
	right: Value_ID,
}

Unary :: struct {
	op:      Unary_Op,
	operand: Value_ID,
}

Compare :: struct {
	op:    Compare_Op,
	left:  Value_ID,
	right: Value_ID,
}

// Phi stands before every other instruction of its block. Build it with phi and phi_incoming: a
// loop header learns its back edge only once the body is built.
Phi :: struct {
	incoming: []Incoming,
}

// Convert is exact: it never narrows an integer, and it turns an F64 into an integer only where opt
// proved one that fits.
Convert :: struct {
	value: Value_ID,
}

// Alloc takes a cell, zero filled, and answers a reference to it. Only an object or an environment
// layout: an array is New_Array, a closure Make_Closure, and a string is made by the runtime. The
// header names `table`, a row that lists the fields of the layout in another print order (see
// Program_IR.base); NO_LAYOUT names the layout's own row.
Alloc :: struct {
	layout: Layout_ID,
	table:  Layout_ID,
	place:  Cell_Place,
}

// Cell_Place Stack: no reference to the cell outlives the call or the loop pass that made it,
// enters a heap cell or reaches the runtime, and a New_Array there has a constant length of at
// most MAX_STACK_ELEMENTS.
Cell_Place :: enum u8 {
	Heap,
	Stack,
}

MAX_STACK_ELEMENTS :: 16

// cell_place answers nil for an instruction that makes no cell.
cell_place :: proc(variant: ^Variant) -> ^Cell_Place {
	#partial switch &v in variant {
	case Alloc:
		return &v.place
	case New_Array:
		return &v.place
	case Make_Closure:
		return &v.place
	}
	return nil
}

// cell_size answers the bytes a cell takes in its slot on the stack; ok is false for a value that
// cannot go there.
cell_size :: proc(p: Program_IR, func: Func, value: Value_ID) -> (size: int, ok: bool) {
	#partial switch v in func.values[value].variant {
	case Alloc:
		return p.layouts[v.layout].size, true
	case Make_Closure:
		return size_of(abi.Closure_Cell), true
	case New_Array:
		if int(v.length) >= len(func.values) {
			return 0, false
		}
		length, fixed := func.values[v.length].variant.(Const_Number)
		n := length.value
		if !fixed || n != math.trunc(n) || n < 0 || n > MAX_STACK_ELEMENTS {
			return 0, false
		}
		return size_of(abi.Array_Cell) + int(n) * abi.SLOT_SIZE[p.layouts[v.layout].element], true
	}
	return 0, false
}

// New_Array answers an array of an Array layout holding `length` elements (an F64), each the zero
// of its kind, which the code after it fills in place. A Ref element starts as the null reference,
// so every one is stored before anything else can reach the array.
New_Array :: struct {
	layout: Layout_ID,
	length: Value_ID,
	place:  Cell_Place,
}

Field_Load :: struct {
	cell:  Value_ID,
	field: i32, // index into the fields of the layout
}

// Field_Store writes a Number or a Boolean slot.
Field_Store :: struct {
	cell:  Value_ID,
	field: i32,
	value: Value_ID,
}

// Field_Store_Ref writes a Ref or a Tagged slot, the two kinds the collector traces. Every
// reference that enters a heap cell goes through a store that ends in _Ref, which is where the
// write barrier of the concurrent collector lands in v2.
Field_Store_Ref :: struct {
	cell:  Value_ID,
	field: i32,
	value: Value_ID,
}

// Length answers the length of a Str or of an array Ref as F64, or as I64 once opt narrowed it: one
// load, since abi puts the two at the same offset.
Length :: struct {
	value: Value_ID,
}

// Reserve makes room past the length of an array for one more element, growing its buffer when it
// is full, which may collect. Set_Length then takes the slot in; a push is the two of them.
Reserve :: struct {
	array: Value_ID,
}

// Set_Length writes the length of an array, a number no more than its capacity. The slots past a
// shortened length keep their bits: the collector reads only the first `length`.
Set_Length :: struct {
	array:  Value_ID,
	length: Value_ID,
}

// Bounds_Check answers the index again, in the index's number type, once it has proved that the
// index is an integer inside the array, or inside the string, whose unit Unit_Load then reads.
// The element instructions take that answer, so the check cannot drift away from the access it
// guards, and opt, which proves checks away, has an edge to follow.
Bounds_Check :: struct {
	array:        Value_ID,
	index:        Value_ID,
	not_integer:  Fail_Site_ID,
	out_of_range: Fail_Site_ID,
	proved:       bool, // codegen emits nothing for it, and the fail sites are unused
}

Element_Load :: struct {
	array: Value_ID,
	index: Value_ID, // the answer of a Bounds_Check
}

// Element_Store writes a Number or a Boolean element.
Element_Store :: struct {
	array: Value_ID,
	index: Value_ID,
	value: Value_ID,
}

// Element_Store_Ref writes a Ref or a Tagged element; see Field_Store_Ref.
Element_Store_Ref :: struct {
	array: Value_ID,
	index: Value_ID,
	value: Value_ID,
}

// Unit_Load answers the UTF-16 unit of a Str as F64, or as I32 once opt narrowed it.
Unit_Load :: struct {
	text:  Value_ID,
	index: Value_ID, // the answer of a Bounds_Check
}

// Ascii_Cell answers the one-unit string of a unit below ASCII_LIMIT, which a branch before it
// proved, as a row of a table of static cells codegen emits.
Ascii_Cell :: struct {
	unit: Value_ID, // the answer of a Unit_Load
}

ASCII_LIMIT :: abi.ASCII_LIMIT

// Layout_Test answers Bool: whether the cell's type table is a row whose base is this layout. A
// Tag_Test says only that a tagged value holds an object; a read of an object out of a slot that
// holds any object needs this as well before it trusts the layout.
Layout_Test :: struct {
	cell:   Value_ID,
	layout: Layout_ID,
}

// Null_Test answers Bool: whether a reference is null. A reference type that may hold null is null
// for its nullish value; a present one is null only as the mark that the declaration of its
// binding has not run yet where a read may come first (the read check of lower).
Null_Test :: struct {
	value: Value_ID,
}

// Non_Null answers a reference that may hold null as its present type, once a Null_Test before it
// proved it is not null.
Non_Null :: struct {
	value: Value_ID,
}

// As_Layout answers an Any_Ref as a reference of the layout its type names, once a Layout_Test before
// it proved the cell has that layout.
As_Layout :: struct {
	cell: Value_ID,
}

// Same_Cell answers Bool: whether two Str are one cell. Two cells may hold the same units, so only
// a test in front of the comparison of contents may use it.
Same_Cell :: struct {
	a: Value_ID,
	b: Value_ID,
}

// Tag_Test answers whether the tag of a Tagged value is in the set. It is what narrowing compiles
// to. A set says in one instruction what would otherwise be a chain of branches, since Binary takes
// numbers only: `x == null` is {Undefined, Null}, `typeof x === "object"` is {Object, Null}.
Tag_Test :: struct {
	value: Value_ID,
	tags:  Tag_Set,
}

Tag_Set :: bit_set[abi.Tag]

// Box wraps a statically typed value as Tagged; a null reference of a type that may hold one boxes
// as its nullish. Unbox reads it back, and the type of the instruction says as what: the payload of
// null and undefined is 0, the null reference. Unbox does not check: a Tag_Test, or a Fail, comes
// before it.
Box :: struct {
	value: Value_ID,
}

Unbox :: struct {
	value: Value_ID,
}

Global_Load :: struct {
	global: Global_ID,
}

Global_Store :: struct {
	global: Global_ID,
	value:  Value_ID,
}

// Env is the environment of a closure body, typed ref(Func.env) of the function it stands in.
Env :: struct {}

// Func_Ref answers the static closure of a function with no environment, a module-level
// declaration: Node makes that value once, when the module is instantiated, so every read of the
// name answers the same cell. The function must be described (describe_func).
Func_Ref :: struct {
	func: Func_ID,
}

// Make_Closure answers a new closure cell, since Node gives every evaluation of an arrow or of a
// nested declaration an identity of its own. env is a ref(Func.env) the caller filled, or NO_VALUE
// exactly when the function has no environment. The cell takes env without a store of its own, so
// the write barrier of v2 has to look here as well as at the stores that end in _Ref. The function
// must be described (describe_func).
Make_Closure :: struct {
	func:  Func_ID,
	env:   Value_ID,
	place: Cell_Place,
}

// Call names a function of this program, so it resolves statically. env is as in Make_Closure:
// lower calls only functions with no environment directly, and opt calls one that has an
// environment where it sees the closure being made.
Call :: struct {
	func: Func_ID,
	env:  Value_ID,
	args: []Value_ID,
}

// Call_Closure calls a function value: code and environment, in the abi calling convention. A
// closure carries no signature, so the arguments and the type of the instruction are those of the
// function behind it, which lower guarantees.
Call_Closure :: struct {
	callee: Value_ID, // a Closure
	args:   []Value_ID,
}

Call_Runtime :: struct {
	export: abi.Runtime_Proc,
	args:   []Value_ID,
}

// Intrinsic is a number function codegen emits itself rather than calling the runtime.
Intrinsic :: struct {
	op:   Intrinsic_Op,
	args: []Value_ID,
}

Jump :: struct {
	target: Block_ID,
}

Branch :: struct {
	condition:  Value_ID, // a Bool
	then_block: Block_ID,
	else_block: Block_ID,
}

// Return carries NO_VALUE when the result of the function is Void.
Return :: struct {
	value: Value_ID,
}

// Fail hands the site to the runtime, which prints it and exits with code 1. It ends its block:
// the runtime never comes back.
Fail :: struct {
	site: Fail_Site_ID,
}

// Unreachable ends a block control cannot leave, after a call that never returns such as
// process.exit. It keeps lower from inventing a Return whose value does not exist, and it lets the
// verifier tell that block from one whose terminator is missing.
Unreachable :: struct {}

// terminates names the terminators: every block ends with exactly one of them.
terminates :: proc(variant: Variant) -> bool {
	switch _ in variant {
	case Jump, Branch, Return, Fail, Unreachable:
		return true
	case Param, Const_Number, Const_Bool, Const_Undefined, Const_Null, Const_String:
		return false
	case Binary, Unary, Compare, Phi, Convert:
		return false
	case Alloc, New_Array, Field_Load, Field_Store, Field_Store_Ref, Length, Reserve, Set_Length:
		return false
	case Bounds_Check, Element_Load, Element_Store, Element_Store_Ref, Layout_Test, Null_Test:
		return false
	case Unit_Load, Ascii_Cell, Same_Cell, Non_Null, As_Layout:
		return false
	case Tag_Test, Box, Unbox, Global_Load, Global_Store:
		return false
	case Env, Func_Ref, Make_Closure:
		return false
	case Call, Call_Closure, Call_Runtime, Intrinsic:
		return false
	}
	return false
}

// Binary_Op: Add, Subtract, Multiply and Remainder take and answer one number type, Divide and
// Power only F64. The bitwise operators take any number type and answer F64 or I32, an unsigned
// shift F64 or I64. An integer operation computes what the F64 one would: opt narrows only what it
// proved to fit, and a Remainder only of a dividend it proved non-negative and a divisor it proved
// not 0.
//
// The bitwise and shift operators are the ones ECMAScript defines, not the ones the machine has:
// each operand goes through ToInt32, or ToUint32 on the left of an unsigned shift, the shift count
// is taken modulo 32, and the 32-bit result converts back to f64. Naming the rule here keeps it in
// one place: codegen implements an operation of this IR, and opt narrows it without changing what
// it means.
//
// Power is ** and Math.pow, which is ECMAScript exponentiation. It differs from the pow of libm in
// one corner, pow(1, NaN) is NaN, so it is not a plain call to libm.
Binary_Op :: enum u8 {
	Add,
	Subtract,
	Multiply,
	Divide,
	Remainder,
	Power,
	Shift_Left,
	Shift_Right,
	Shift_Right_Unsigned,
	Bit_And,
	Bit_Or,
	Bit_Xor,
}

// Compare_Op answers Bool. Two F64 compare by IEEE rules, so NaN is equal to nothing and -0 equals
// 0, which is what === asks for; two integers of one type compare as signed integers. Equal and
// Not_Equal also take two Bool, or two references, where they compare addresses. A string and a
// tagged value compare through the runtime instead: one holds its contents and the other its tag.
// lower tests two strings with Same_Cell, Length and Unit_Load before it asks the runtime.
Compare_Op :: enum u8 {
	Less,
	Less_Equal,
	Greater,
	Greater_Equal,
	Equal,
	Not_Equal,
}

// Unary_Op: Negate takes and answers one number type, Bit_Not takes any and answers F64 or I32 as
// the bitwise Binary_Op do, Not takes Bool. Unary plus is nothing to do and typeof reads a tag, so
// neither is here.
Unary_Op :: enum u8 {
	Negate,
	Not,
	Bit_Not,
}

// Intrinsic_Op is a number function codegen emits inline, as an llvm.*.f64 intrinsic or a call to
// libm. Min and Max are Math.min and Math.max of two numbers, which lower folds a longer call into.
// The Math names that need more stay out of it: round goes to the runtime, hypot takes any number
// of arguments, and fround, clz32, imul and sign expand into other instructions.
// Math.pow is Binary_Op.Power. lower owns the table from a lib name to one of these.
Intrinsic_Op :: enum u8 {
	Abs,
	Sqrt,
	Floor,
	Ceil,
	Trunc,
	Sin,
	Cos,
	Tan,
	Asin,
	Acos,
	Atan,
	Atan2,
	Sinh,
	Cosh,
	Tanh,
	Asinh,
	Acosh,
	Atanh,
	Exp,
	Expm1,
	Log,
	Log1p,
	Log2,
	Log10,
	Cbrt,
	Min,
	Max,
}
