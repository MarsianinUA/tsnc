/*
Our own intermediate representation: the program with every TypeScript rule already resolved. lower
builds a Program_IR, opt rewrites it in v2, codegen walks it with one exhaustive switch, the
-emit-ir dump prints it and verify answers whether it keeps to the rules below. Nothing here knows
TypeScript. What the source leaves implicit becomes an
instruction of its own: a tag check, a bounds check, a reference store, a runtime call.

Shape: static single assignment. A Func keeps its blocks and its instructions in two flat arrays and
every reference between them is a distinct index, never a pointer, so a function can be walked,
printed and copied without chasing memory. A Value_ID is the instruction that defines the value.

IDs and sentinels:
- Func_ID, Global_ID, Layout_ID, String_ID and Fail_Site_ID index the arrays of Program_IR.
  Block_ID and Value_ID index the arrays of one Func and mean nothing in another one.
- NO_LAYOUT is layout 0, a reserved row, so a zero Type reads as Void and two types compare with ==.
- NO_VALUE and NO_BLOCK are the largest index rather than zero, because value 0 is a real
  instruction, the first parameter of the entry block. ast.ROOT can be its own sentinel only because
  the root is never a child.
- Values are numbered in the order they were emitted, which crosses block boundaries and is not
  dominance order: a loop header receives its phi before the body that feeds it is built. So a
  reader that wants every definition before its uses walks the blocks in reverse post-order rather
  than comparing two Value_ID values.

Layouts are the GC type tables. lower interns a layout by the canonical shape of a cell and gets a
Layout_ID; the rows are abi.Type_Table values, so what lower interns is exactly what codegen emits
as static data and what the collector reads at run time. There is no second description of a cell.

Failure sites are resolved here rather than in codegen. abi.Fail_Site wants a path, a line and a
column, and only source can turn a byte offset into a line and a column; codegen depends on ir, abi,
target and llvm, not on source. So lower resolves the position and Program_IR carries the sites.

Memory: everything in a Program_IR comes from the allocator its builder was made with, which is
meant to be an arena, and ir never frees. Names and paths are borrowed from the caller and must
outlive the result, the way ast borrows the source text.
*/
package ir

import "../abi"
import "../source"

Func_ID :: distinct u32
Global_ID :: distinct u32
Layout_ID :: distinct u32
String_ID :: distinct u32
Fail_Site_ID :: distinct u32
Block_ID :: distinct u32
Value_ID :: distinct u32

// ENTRY is never the target of a jump.
ENTRY :: Block_ID(0)

// NO_LAYOUT takes row 0 of Program_IR.layouts, which is reserved for it.
NO_LAYOUT :: Layout_ID(0)

// NO_VALUE means an operand is absent, as in a Return with no result.
NO_VALUE :: Value_ID(max(u32))

// NO_BLOCK means the builder has no open block: a terminator closed the last one.
NO_BLOCK :: Block_ID(max(u32))

// Type_Kind gains I32 and I64 for narrowed integers in v2.
Type_Kind :: enum u8 {
	Void,
	F64, // number
	Bool,
	Tagged, // any or a union: abi.Tagged, two words
	Str, // a reference to an abi.String_Cell
	Closure, // a reference to an abi.Closure_Cell: code plus environment
	Ref, // a reference to the cell of a layout: object, array, environment
}

// Type is comparable with ==: layout is NO_LAYOUT for every kind but Ref.
Type :: struct {
	kind:   Type_Kind,
	layout: Layout_ID,
}

VOID :: Type{}
F64 :: Type {
	kind = .F64,
}
BOOL :: Type {
	kind = .Bool,
}
TAGGED :: Type {
	kind = .Tagged,
}
STR :: Type {
	kind = .Str,
}
CLOSURE :: Type {
	kind = .Closure,
}

ref :: proc(layout: Layout_ID) -> Type {
	assert(layout != NO_LAYOUT, "a reference type needs a layout")
	return {kind = .Ref, layout = layout}
}

// Slot is one field of an object layout or one captured variable of an environment, in the
// canonical order lower chose. The layout procedures turn slots into abi.Field offsets.
Slot :: struct {
	name: string, // UTF-8 TS name; empty in an environment
	kind: abi.Slot_Kind,
}

// Global is a module-level binding, zero filled before any module runs, so a Tagged global starts
// as undefined: abi.Tag.Undefined is zero.
Global :: struct {
	name: string, // unique in the program
	type: Type,
}

Block :: struct {
	instructions: []Value_ID, // in order; the last one terminates
}

// Func takes a closure's environment as a hidden first parameter in the abi calling convention, so
// env names that environment's layout and params holds the TS parameters alone.
Func :: struct {
	name:   string, // the symbol codegen emits; unique in the program
	span:   source.Span,
	params: []Type,
	result: Type,
	env:    Layout_ID, // NO_LAYOUT when the function captures nothing
	blocks: []Block, // blocks[ENTRY] is the entry block
	values: []Instruction, // indexed by Value_ID, in the order they were emitted
}

// Unit is the part of the program one codegen call compiles into one LLVM module. v1 has one unit
// holding every function; v2 cuts the program into several and optimizes them in parallel.
Unit :: struct {
	funcs: []Func_ID,
}

// Program_IR is frozen once lower returns it: only opt rewrites it, and only in v2, because "IR to
// IR" is that package's contract.
Program_IR :: struct {
	funcs:      []Func, // indexed by Func_ID
	layouts:    []abi.Type_Table, // indexed by Layout_ID; the GC type tables; row 0 is reserved
	globals:    []Global, // indexed by Global_ID
	strings:    [][]u16, // indexed by String_ID; the units of the cells codegen emits
	fail_sites: []abi.Fail_Site, // indexed by Fail_Site_ID
	init_order: []Func_ID, // the module init functions, in the order main calls them
	main:       Func_ID, // the function that takes the abi.MAIN_SYMBOL name
	units:      []Unit,
}

// table_id numbers a layout after the tables whose shape no program can change, so that the
// identifier in a cell header means the same thing to the compiler and to the collector.
table_id :: proc(layout: Layout_ID) -> abi.Type_Table_ID {
	assert(layout != NO_LAYOUT, "the reserved layout row has no type table")
	return abi.Type_Table_ID(len(abi.Builtin_Table) + int(layout) - 1)
}

// A slot of a cell is placed at the running sum of the sizes before it, with no padding between
// them. That holds because every slot is a multiple of 8 bytes and needs no more alignment than the
// header already has.
#assert(align_of(abi.Tagged) == 8)
#assert(size_of(abi.Cell_Header) % 8 == 0)
