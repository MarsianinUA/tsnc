package arr

import "../../abi"
import "../gc"
import "../num"
import "../str"
import "../value"

/*
Joining, and ToString of an array, which is its elements joined by commas. The units of every
element go into one scratch buffer in context.allocator, numbers straight from num.to_string, so a
join allocates in the GC heap once, for the result, and no element's string has to outlive its turn.
*/

@(private)
COMMA :: string16(",")

// join is Array.prototype.join. undefined and null add nothing, and a nested array adds its own
// join by commas. An array that is already being joined further out adds nothing either, as in V8,
// so `a = [1]; a.push(a)` joins to "1,". ok = false where value.to_string refuses an element.
join :: proc(
	heap: ^gc.Heap,
	array: ^abi.Array_Cell,
	separator: ^abi.String_Cell,
) -> (
	text: ^abi.String_Cell,
	ok: bool,
) {
	return join_units(heap, array, str.units(separator))
}

// to_string is ToString of a tagged value: an array joins by commas, anything else is value's.
to_string :: proc(heap: ^gc.Heap, v: abi.Tagged) -> (text: ^abi.String_Cell, ok: bool) {
	if array, is_array := as_array(heap, v); is_array {
		return join_units(heap, array, COMMA)
	}
	return value.to_string(heap, v)
}

// to_primitive_string is ToString(ToPrimitive(v)), the string `+` joins. ToPrimitive asks an object
// for its valueOf before its toString, so an object with a valueOf of its own answers ok = false,
// as one with its own toString does (value.own_method). An array has neither, and its elements
// stay ToString.
to_primitive_string :: proc(heap: ^gc.Heap, v: abi.Tagged) -> (text: ^abi.String_Cell, ok: bool) {
	if v.tag == .Object {
		if _, found := value.own_method(heap, v.payload.ref, "valueOf"); found {
			return nil, false
		}
	}
	return to_string(heap, v)
}

// append_string appends the units of ToString(v), so a caller that only reads the text makes no
// cell for it. ok = false where to_string would refuse.
append_string :: proc(units: ^[dynamic]u16, heap: ^gc.Heap, v: abi.Tagged) -> (ok: bool) {
	return write_string(units, heap, v, nil)
}

@(private)
join_units :: proc(
	heap: ^gc.Heap,
	array: ^abi.Array_Cell,
	separator: string16,
) -> (
	text: ^abi.String_Cell,
	ok: bool,
) {
	units := make([dynamic]u16)
	defer delete(units)
	write_elements(&units, heap, array, separator, nil) or_return
	return str.from_units(heap, string16(units[:])), true
}

@(private)
Join_Frame :: struct {
	array: ^abi.Array_Cell,
	outer: ^Join_Frame,
	start: int, // where in the units the string being written begins; sort_default writes many
}

@(private)
write_elements :: proc(
	units: ^[dynamic]u16,
	heap: ^gc.Heap,
	array: ^abi.Array_Cell,
	separator: string16,
	outer: ^Join_Frame,
) -> bool {
	for frame := outer; frame != nil; frame = frame.outer {
		if frame.array == array {
			return true
		}
	}
	frame := Join_Frame{array, outer, outer.start if outer != nil else len(units^)}
	kind := element_kind(heap, array)
	for i in 0 ..< array.length {
		// Checked as the string grows, so a join Node refuses fails before it fills the memory.
		str.ensure_length(len(units^) - frame.start)
		if i > 0 {
			append(units, ..transmute([]u16)separator)
		}
		element := value.load(heap, slot(array, kind, i), kind)
		if element.tag == .Undefined || element.tag == .Null {
			continue
		}
		write_string(units, heap, element, &frame) or_return
	}
	return true
}

// write_string appends the units of ToString(v). `frame` is the innermost array being joined, or
// nil at the top.
@(private)
write_string :: proc(
	units: ^[dynamic]u16,
	heap: ^gc.Heap,
	v: abi.Tagged,
	frame: ^Join_Frame,
) -> bool {
	if v.tag == .Number {
		// value.to_string would put the digits in a cell of their own first.
		buf: [num.STRING_MAX]byte
		digits := num.to_string(buf[:], v.payload.number)
		for i in 0 ..< len(digits) {
			append(units, u16(digits[i]))
		}
		return true
	}
	if array, is_array := as_array(heap, v); is_array {
		return write_elements(units, heap, array, COMMA, frame)
	}
	text := value.to_string(heap, v) or_return
	append(units, ..transmute([]u16)str.units(text))
	return true
}

@(private)
as_array :: proc(heap: ^gc.Heap, v: abi.Tagged) -> (array: ^abi.Array_Cell, is_array: bool) {
	if v.tag != .Object {
		return nil, false
	}
	return (^abi.Array_Cell)(v.payload.ref), gc.table_of(heap, v.payload.ref).kind == .Array
}
