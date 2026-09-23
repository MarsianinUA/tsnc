/*
Tagged values: an `any`, or a union whose members differ in shape (requirements 3.4). The
operations here dispatch on the tag at run time, with the semantics of ECMAScript's typeof,
IsStrictlyEqual (requirements 3.7), ToBoolean and ToString.

The words they answer are static cells, so nothing here allocates but the digits of a number.

An array is not converted here: its string is its elements joined by commas, and joining is
package arr's, which imports this one.
*/
package value

import "../../abi"
import "../gc"
import "../str"

typeof_word :: proc(v: abi.Tagged) -> ^abi.String_Cell {
	switch v.tag {
	case .Undefined:
		return word(.Undefined)
	case .Null, .Object:
		return word(.Object)
	case .Boolean:
		return word(.Boolean)
	case .Number:
		return word(.Number)
	case .String:
		return word(.String)
	case .Function:
		return word(.Function)
	}
	unreachable()
}

// equal is `===`. Numbers compare as f64, so NaN is not NaN and -0 is 0.
equal :: proc(a, b: abi.Tagged) -> bool {
	if a.tag != b.tag {
		return false
	}
	switch a.tag {
	case .Undefined, .Null:
		return true
	case .Boolean:
		return a.payload.boolean == b.payload.boolean
	case .Number:
		return a.payload.number == b.payload.number
	case .String:
		return str.equal(string_cell(a), string_cell(b))
	case .Object, .Function:
		return a.payload.ref == b.payload.ref
	}
	unreachable()
}

to_boolean :: proc(v: abi.Tagged) -> bool {
	switch v.tag {
	case .Undefined, .Null:
		return false
	case .Boolean:
		return bool(v.payload.boolean)
	case .Number:
		// NaN fails the first test, both zeros the second.
		n := v.payload.number
		return n == n && n != 0
	case .String:
		return string_cell(v).length != 0
	case .Object, .Function:
		return true
	}
	unreachable()
}

// to_string answers ok = false where Node runs code tsnc does not have: it prints a function's
// source text, and it calls an object's own toString.
to_string :: proc(heap: ^gc.Heap, v: abi.Tagged) -> (text: ^abi.String_Cell, ok: bool) {
	switch v.tag {
	case .Undefined:
		return word(.Undefined), true
	case .Null:
		return word(.Null), true
	case .Boolean:
		return word(.True if v.payload.boolean else .False), true
	case .Number:
		return str.from_number(heap, v.payload.number), true
	case .String:
		return string_cell(v), true
	case .Object:
		table, known := gc.type_table(heap, v.payload.ref.type_table)
		ensure(known, "a cell of an unregistered type table")
		ensure(table.kind == .Object, "a tagged object that is no object; arr converts an array")
		for field in table.fields {
			if field.name == "toString" {
				return nil, false
			}
		}
		return word(.Object_Text), true
	case .Function:
		return nil, false
	}
	unreachable()
}

@(private)
string_cell :: proc "contextless" (v: abi.Tagged) -> ^abi.String_Cell {
	return (^abi.String_Cell)(v.payload.ref)
}

@(private)
Word :: enum u8 {
	Undefined,
	Null,
	True,
	False,
	Boolean,
	Number,
	String,
	Object,
	Function,
	Object_Text, // [object Object]
}

// Word_Cell is a string cell in static data: the header, then its units, as String_Cell lays them
// out in the heap.
@(private)
Word_Cell :: struct {
	cell:  abi.String_Cell,
	units: [15]u16,
}
#assert(offset_of(Word_Cell, units) == size_of(abi.String_Cell))

@(private)
STRING :: abi.Type_Table_ID(abi.Builtin_Table.String)

@(private, rodata)
WORDS := [Word]Word_Cell {
	.Undefined = {
		cell = {type_table = STRING, length = 9},
		units = {'u', 'n', 'd', 'e', 'f', 'i', 'n', 'e', 'd', 0, 0, 0, 0, 0, 0},
	},
	.Null = {
		cell = {type_table = STRING, length = 4},
		units = {'n', 'u', 'l', 'l', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	},
	.True = {
		cell = {type_table = STRING, length = 4},
		units = {'t', 'r', 'u', 'e', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	},
	.False = {
		cell = {type_table = STRING, length = 5},
		units = {'f', 'a', 'l', 's', 'e', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
	},
	.Boolean = {
		cell = {type_table = STRING, length = 7},
		units = {'b', 'o', 'o', 'l', 'e', 'a', 'n', 0, 0, 0, 0, 0, 0, 0, 0},
	},
	.Number = {
		cell = {type_table = STRING, length = 6},
		units = {'n', 'u', 'm', 'b', 'e', 'r', 0, 0, 0, 0, 0, 0, 0, 0, 0},
	},
	.String = {
		cell = {type_table = STRING, length = 6},
		units = {'s', 't', 'r', 'i', 'n', 'g', 0, 0, 0, 0, 0, 0, 0, 0, 0},
	},
	.Object = {
		cell = {type_table = STRING, length = 6},
		units = {'o', 'b', 'j', 'e', 'c', 't', 0, 0, 0, 0, 0, 0, 0, 0, 0},
	},
	.Function = {
		cell = {type_table = STRING, length = 8},
		units = {'f', 'u', 'n', 'c', 't', 'i', 'o', 'n', 0, 0, 0, 0, 0, 0, 0},
	},
	.Object_Text = {
		cell = {type_table = STRING, length = 15},
		units = {'[', 'o', 'b', 'j', 'e', 'c', 't', ' ', 'O', 'b', 'j', 'e', 'c', 't', ']'},
	},
}

@(private)
word :: proc "contextless" (w: Word) -> ^abi.String_Cell {
	return &WORDS[w].cell
}
