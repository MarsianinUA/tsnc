package console_tests

import "core:testing"
import "core:unicode/utf16"

import "../../../src/abi"
import "../../../src/runtime/arr"
import "../../../src/runtime/console"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"

/*
Values for the format test, built by hand the way generated code lays them out. What console.log
prints is pinned by the programs of tests/diff; the tests here check what no program reaches. They
stay far below gc.MIN_TRIGGER, so no collection runs and the cells may live in the test procedure.
*/

RESERVE :: 64 * gc.PAGE_SIZE

// The program tables TABLES registers, numbered after the builtin ones.
VALUES :: abi.Type_Table_ID(len(abi.Builtin_Table))
CLOSURE :: VALUES + 1
PRINTABLE :: VALUES + 2
VALUE_OF :: VALUES + 3
TO_JSON :: VALUES + 4

TABLES := []abi.Type_Table {
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Tagged},
	{kind = .Closure, size = size_of(abi.Closure_Cell)},
	{kind = .Object, size = 24, fields = {{name = "toString", offset = 8, kind = .Tagged}}},
	{kind = .Object, size = 24, fields = {{name = "valueOf", offset = 8, kind = .Tagged}}},
	{kind = .Object, size = 24, fields = {{name = "toJSON", offset = 8, kind = .Tagged}}},
}

init_heap :: proc(t: ^testing.T, heap: ^gc.Heap, loc := #caller_location) {
	err := gc.heap_init(heap, TABLES, nil, heap, reserve = RESERVE)
	testing.expect_value(t, err, gc.Heap_Error.None, loc = loc)
}

// render is the line console.log writes for `args`, less its newline, in UTF-8. It allocates from
// the temp allocator, as the runtime's exports do from their scratch arena.
render :: proc(heap: ^gc.Heap, args: []abi.Tagged) -> (line: string, err: console.Format_Error) {
	context.allocator = context.temp_allocator
	units := make([dynamic]u16)
	err = console.format(heap, args, false, &units)
	bytes := make([]byte, 4 * len(units))
	return string(bytes[:utf16.decode_to_utf8(bytes, units[:])]), err
}

number :: proc(n: f64) -> abi.Tagged {
	return {tag = .Number, payload = {number = n}}
}

text :: proc(heap: ^gc.Heap, s: string) -> abi.Tagged {
	return {tag = .String, payload = {ref = str.from_utf8(heap, s)}}
}

values :: proc(heap: ^gc.Heap, items: ..abi.Tagged) -> abi.Tagged {
	array := arr.new_array(heap, VALUES, len(items))
	for item in items {
		arr.push(heap, array, item)
	}
	return {tag = .Object, payload = {ref = array}}
}

// object fills the fields of `table` in table order with `fields`.
object :: proc(heap: ^gc.Heap, table: abi.Type_Table_ID, fields: ..abi.Tagged) -> abi.Tagged {
	layout := TABLES[int(table) - len(abi.Builtin_Table)]
	cell := gc.alloc(heap, table, layout.size)
	for field, i in layout.fields {
		set_field(cell, field, fields[i])
	}
	return {tag = .Object, payload = {ref = cell}}
}

set_field :: proc(cell: ^abi.Cell_Header, field: abi.Field, v: abi.Tagged) {
	slot := &([^]byte)(cell)[field.offset]
	switch field.kind {
	case .Number:
		(^f64)(slot)^ = v.payload.number
	case .Boolean:
		(^b64)(slot)^ = v.payload.boolean
	case .Ref, .Ref_Or_Null, .Ref_Or_Undefined:
		(^^abi.Cell_Header)(slot)^ = v.payload.ref
	case .Tagged:
		(^abi.Tagged)(slot)^ = v
	}
}

// function makes a closure whose Function_Info lives in the temp allocator, where a compiled
// program has static data.
function :: proc(heap: ^gc.Heap, name: string, length: int, has_prototype: bool) -> abi.Tagged {
	info := new(abi.Function_Info, context.temp_allocator)
	info^ = {
		name          = str.from_utf8(heap, name),
		length        = length,
		has_prototype = has_prototype,
	}
	closure := (^abi.Closure_Cell)(gc.alloc(heap, CLOSURE, size_of(abi.Closure_Cell)))
	closure.info = info
	return {tag = .Function, payload = {ref = closure}}
}
