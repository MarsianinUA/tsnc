/*
The contract between generated code and the runtime: cell layouts, tags, the GC type table format,
runtime exports and error codes. The compiler (lower, codegen) and the runtime (rt and its
subpackages) both import this package, so every layout and name has exactly one definition. A change
here is a change to both sides at once.

The package holds data only and imports nothing, so the runtime can import it without pulling in the
compiler or core.

v1 targets are 64-bit and the host is the target, so codegen takes sizes and offsets from size_of
and offset_of of these structs. The #asserts at the end of this file pin what codegen maps to LLVM
types.

Memory rules:
- Every cell starts with a Cell_Header, whether it lives in the GC heap or in static data. A static
  cell is read-only: the GC marks and frees only cells in its own heap.
- A reference is a plain pointer to the start of a cell. Generated code never disguises pointers.
- A slot other than Tagged is one 8-byte word; a boolean is b64, 0 or 1.
*/
package abi

// Type_Table_ID indexes the type tables: Builtin_Table first, then the tables the compiler emits.
Type_Table_ID :: distinct u32

Cell_Flag :: enum u32 {
	Marked,
}
Cell_Flags :: bit_set[Cell_Flag;u32]

Cell_Header :: struct {
	type_table: Type_Table_ID,
	flags:      Cell_Flags, // owned by gc
}

// String_Cell holds an immutable UTF-16 string.
String_Cell :: struct {
	using header: Cell_Header,
	length:       int, // in UTF-16 units
	units:        [0]u16, // `length` units follow the struct
}

Array_Cell :: struct {
	using header: Cell_Header,
	length:       int,
	capacity:     int,
	// First of `capacity` unboxed slots of the type table's element kind. The slots live in a
	// separate GC allocation, so the array can grow while references to it stay valid.
	elements:     rawptr,
}

// Closure_Cell is a function value. `code` points to a procedure with the closure calling
// convention: proc "c" (env: ^Environment_Cell, <TS parameters>) -> <TS result>. One Odin type
// cannot describe every TS signature, so the runtime casts `code` to the concrete type it calls.
Closure_Cell :: struct {
	using header: Cell_Header,
	code:         rawptr,
	env:          ^Environment_Cell, // nil when the function captures nothing
}

// Environment_Cell holds the variables a closure captured. The slots follow the header at the
// offsets its type table gives.
Environment_Cell :: struct {
	using header: Cell_Header,
}

// Tag says what a Tagged value holds. Undefined is the zero value, so zeroed memory reads as
// undefined.
Tag :: enum u64 {
	Undefined,
	Null,
	Boolean,
	Number,
	String,
	Object, // objects and arrays; the cell's type table tells them apart
	Function,
}

// Payload is read through the field its tag names. Undefined and Null leave it zero.
Payload :: struct #raw_union {
	number:  f64,
	boolean: b64,
	ref:     ^Cell_Header, // String, Object, Function
}

// Tagged is a value of type `any` or a union: two words, numbers and booleans stored inline.
Tagged :: struct {
	tag:     Tag,
	payload: Payload,
}

// Slot_Kind says what one slot of a cell holds: an object field, a captured variable, an array
// element.
Slot_Kind :: enum u8 {
	Number, // f64
	Boolean, // b64
	Ref, // ^Cell_Header, traced by the GC
	Tagged, // Tagged, the GC traces payload.ref when the tag holds a reference
}

// SLOT_SIZE is @(rodata) rather than a constant: Odin indexes a constant array only by a constant,
// and its readers index it by the slot kind of a field.
@(rodata)
SLOT_SIZE := [Slot_Kind]int {
	.Number  = size_of(f64),
	.Boolean = size_of(b64),
	.Ref     = size_of(rawptr),
	.Tagged  = size_of(Tagged),
}

Cell_Kind :: enum u8 {
	Object,
	Environment,
	String,
	Array,
	Closure,
}

Field :: struct {
	name:   string, // UTF-8 TS name; empty in an environment
	offset: int, // bytes from the start of the cell
	kind:   Slot_Kind,
}

// Type_Table tells the GC how to scan a cell and console how to print it. The compiler emits
// these as static data, so the struct is flat: a kind plus the fields that kind reads, not an Odin
// union. `fields` and Field.name keep the Odin layout of a slice and a string, a pointer and a
// length; the #asserts at the end of this file pin every offset codegen writes.
Type_Table :: struct {
	kind:    Cell_Kind,
	size:    int, // bytes, header included; the fixed part for String and Array
	fields:  []Field, // Object and Environment, in layout order
	element: Slot_Kind, // Array
}

// Builtin_Table lists the type tables whose layout does not depend on the program. The compiler
// numbers the tables it emits after these.
Builtin_Table :: enum u32 {
	String,
}

#assert(size_of(rawptr) == 8, "a reference must be 8 bytes: v1 targets are 64-bit")
#assert(size_of(Cell_Header) == 8)
#assert(size_of(Tagged) == 16)
#assert(offset_of(Tagged, payload) == 8)
#assert(offset_of(String_Cell, units) == size_of(String_Cell))

// Static data the compiler emits: type tables and failure sites (calls.odin). A string and a slice
// are a pointer and a length.
#assert(size_of(string) == 16 && size_of([]Field) == 16)
#assert(size_of(Field) == 32 && offset_of(Field, offset) == 16 && offset_of(Field, kind) == 24)
#assert(size_of(Type_Table) == 40 && offset_of(Type_Table, size) == 8)
#assert(offset_of(Type_Table, fields) == 16 && offset_of(Type_Table, element) == 32)
#assert(size_of(Fail_Site) == 32 && offset_of(Fail_Site, line) == 16)
#assert(offset_of(Fail_Site, column) == 20 && offset_of(Fail_Site, error) == 24)
