package console_tests

import "core:testing"
import "core:unicode/utf16"

import "../../../src/abi"
import "../../../src/runtime/arr"
import "../../../src/runtime/console"
import "../../../src/runtime/gc"
import "../../../src/runtime/str"

/*
Values for the inspect and format tests, built by hand the way generated code will lay them out.
The tests stay far below gc.MIN_TRIGGER, so no collection runs and the cells may live in the test
procedure. Every expected string came out of Node 24.13.1; the header of each test names the
expression. Text past ASCII is spelled in UTF-8 bytes, so the source holds no character that a tool
could rewrite.
*/

RESERVE :: 64 * gc.PAGE_SIZE

// The program tables TABLES registers, numbered after the builtin ones.
NUMBERS :: abi.Type_Table_ID(len(abi.Builtin_Table))
BOOLEANS :: NUMBERS + 1
REFS :: NUMBERS + 2
VALUES :: NUMBERS + 3
CLOSURE :: NUMBERS + 4
A :: NUMBERS + 5
B :: NUMBERS + 6
C :: NUMBERS + 7
D :: NUMBERS + 8
EMPTY :: NUMBERS + 9
KEYS :: NUMBERS + 10
QUOTED :: NUMBERS + 11
OPTIONAL :: NUMBERS + 12
REQUIRED :: NUMBERS + 13
SELF :: NUMBERS + 14
K :: NUMBERS + 15
JSON :: NUMBERS + 16
PRINTABLE :: NUMBERS + 17
VALUE_OF :: NUMBERS + 18
TO_JSON :: NUMBERS + 19
ABC :: NUMBERS + 20

// KEYS lists its fields in the order Node prints them, integer keys first, and lays them out in
// another order. QUOTED names a key that needs quotes, one Node spells ['__proto__'], and one in
// Cyrillic.
TABLES := []abi.Type_Table {
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Number},
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Boolean},
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Ref},
	{kind = .Array, size = size_of(abi.Array_Cell), element = .Tagged},
	{kind = .Closure, size = size_of(abi.Closure_Cell)},
	{kind = .Object, size = 24, fields = {{name = "a", offset = 8, kind = .Tagged}}},
	{kind = .Object, size = 24, fields = {{name = "b", offset = 8, kind = .Tagged}}},
	{kind = .Object, size = 24, fields = {{name = "c", offset = 8, kind = .Tagged}}},
	{kind = .Object, size = 24, fields = {{name = "d", offset = 8, kind = .Tagged}}},
	{kind = .Object, size = 8},
	{
		kind = .Object,
		size = 40,
		fields = {
			{name = "1", offset = 32, kind = .Ref},
			{name = "2", offset = 24, kind = .Ref},
			{name = "b", offset = 8, kind = .Number},
			{name = "a", offset = 16, kind = .Number},
		},
	},
	{
		kind = .Object,
		size = 40,
		fields = {
			{name = "a-b", offset = 8, kind = .Number},
			{name = "$d", offset = 16, kind = .Number},
			{name = "__proto__", offset = 24, kind = .Number},
			{name = "\xd0\xba\xd0\xbb\xd1\x8e\xd1\x87", offset = 32, kind = .Number},
		},
	},
	{
		kind = .Object,
		size = 32,
		fields = {
			{name = "x", offset = 8, kind = .Number},
			{name = "y", offset = 16, kind = .Tagged, optional = true},
		},
	},
	{
		kind = .Object,
		size = 32,
		fields = {
			{name = "x", offset = 8, kind = .Number},
			{name = "y", offset = 16, kind = .Tagged},
		},
	},
	{
		kind = .Object,
		size = 32,
		fields = {
			{name = "self", offset = 8, kind = .Tagged},
			{name = "n", offset = 24, kind = .Number},
		},
	},
	{kind = .Object, size = 24, fields = {{name = "k", offset = 8, kind = .Tagged}}},
	{
		kind = .Object,
		size = 56,
		fields = {
			{name = "c", offset = 8, kind = .Tagged},
			{name = "d", offset = 24, kind = .Tagged},
			{name = "e", offset = 40, kind = .Number},
			{name = "f", offset = 48, kind = .Number},
		},
	},
	{kind = .Object, size = 24, fields = {{name = "toString", offset = 8, kind = .Tagged}}},
	{kind = .Object, size = 24, fields = {{name = "valueOf", offset = 8, kind = .Tagged}}},
	{kind = .Object, size = 24, fields = {{name = "toJSON", offset = 8, kind = .Tagged}}},
	{
		kind = .Object,
		size = 32,
		fields = {
			{name = "a", offset = 8, kind = .Ref},
			{name = "b", offset = 16, kind = .Ref},
			{name = "c", offset = 24, kind = .Number},
		},
	},
}

NAN :: 0h7ff8_0000_0000_0000
NEGATIVE_ZERO :: 0h8000_0000_0000_0000

init_heap :: proc(t: ^testing.T, heap: ^gc.Heap, loc := #caller_location) {
	err := gc.heap_init(heap, TABLES, nil, heap, reserve = RESERVE)
	testing.expect_value(t, err, gc.Heap_Error.None, loc = loc)
}

// render is the line console.log writes for `args`, less its newline, in UTF-8. It allocates from
// the temp allocator, as the runtime's exports do from their scratch arena.
render :: proc(
	heap: ^gc.Heap,
	args: []abi.Tagged,
	colors := false,
) -> (
	line: string,
	err: console.Format_Error,
) {
	context.allocator = context.temp_allocator
	units := make([dynamic]u16)
	err = console.format(heap, args, colors, &units)
	bytes := make([]byte, 4 * len(units))
	return string(bytes[:utf16.decode_to_utf8(bytes, units[:])]), err
}

// inspected is util.inspect(v) with the options console.log uses.
inspected :: proc(heap: ^gc.Heap, v: abi.Tagged, colors := false) -> string {
	context.allocator = context.temp_allocator
	units := make([dynamic]u16)
	console.inspect(heap, v, {depth = 2, colors = colors}, &units)
	bytes := make([]byte, 4 * len(units))
	return string(bytes[:utf16.decode_to_utf8(bytes, units[:])])
}

null :: proc() -> abi.Tagged {
	return {tag = .Null}
}

boolean :: proc(b: bool) -> abi.Tagged {
	return {tag = .Boolean, payload = {boolean = b64(b)}}
}

number :: proc(n: f64) -> abi.Tagged {
	return {tag = .Number, payload = {number = n}}
}

text :: proc(heap: ^gc.Heap, s: string) -> abi.Tagged {
	return {tag = .String, payload = {ref = str.from_utf8(heap, s)}}
}

units_text :: proc(heap: ^gc.Heap, units: []u16) -> abi.Tagged {
	return {tag = .String, payload = {ref = str.from_units(heap, string16(units))}}
}

numbers :: proc(heap: ^gc.Heap, items: ..f64) -> abi.Tagged {
	array := arr.new_array(heap, NUMBERS, len(items))
	for item in items {
		arr.push(heap, array, number(item))
	}
	return {tag = .Object, payload = {ref = array}}
}

booleans :: proc(heap: ^gc.Heap, items: ..bool) -> abi.Tagged {
	array := arr.new_array(heap, BOOLEANS, len(items))
	for item in items {
		arr.push(heap, array, boolean(item))
	}
	return {tag = .Object, payload = {ref = array}}
}

values :: proc(heap: ^gc.Heap, items: ..abi.Tagged) -> abi.Tagged {
	array := arr.new_array(heap, VALUES, len(items))
	for item in items {
		arr.push(heap, array, item)
	}
	return {tag = .Object, payload = {ref = array}}
}

strings_array :: proc(heap: ^gc.Heap, items: ..string) -> abi.Tagged {
	array := arr.new_array(heap, REFS, len(items))
	for item in items {
		arr.push(heap, array, text(heap, item))
	}
	return {tag = .Object, payload = {ref = array}}
}

push :: proc(heap: ^gc.Heap, array, item: abi.Tagged) {
	arr.push(heap, (^abi.Array_Cell)(array.payload.ref), item)
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
	case .Ref:
		(^^abi.Cell_Header)(slot)^ = v.payload.ref
	case .Tagged:
		(^abi.Tagged)(slot)^ = v
	}
}

// function makes a closure whose Function_Info lives in the temp allocator, where T5.8 will emit
// static data.
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
