package console

import "core:math"

import "../../abi"
import "../gc"
import "../num"
import "../str"
import "../value"

/*
JSON.stringify of one value, for %j. Node answers "undefined" where JSON.stringify answers
undefined, for undefined itself and a function, and "[Circular]" for a value that contains itself,
where JSON.stringify throws.

An object or an array is walked with a stack of frames in context.allocator rather than by
recursion, so the depth of a value costs heap and not native stack: Node writes a list thousands
deep. The frames are also the ancestors a value is looked for among for [Circular].
*/

@(private)
Json_Result :: enum u8 {
	Written,
	Nothing, // undefined or a function: an array writes null there, an object leaves the key out
	Circular,
	Refused, // an own toJSON function, which Node would call
}

// Json_Frame is an object or an array being written, and how far: the next element or field, and
// for an object whether a field was written yet and where the key of the last one begins, which a
// value that turns out to be nothing takes back out.
@(private)
Json_Frame :: struct {
	cell:  ^abi.Cell_Header,
	table: abi.Type_Table,
	next:  int,
	first: bool,
	mark:  int,
}

@(private)
write_json :: proc(heap: ^gc.Heap, v: abi.Tagged, out: ^[dynamic]u16) -> Format_Error {
	start := len(out)
	frames := make([dynamic]Json_Frame)
	defer delete(frames)
	switch json_value(heap, v, &frames, out) {
	case .Written:
	case .Nothing:
		append_ascii(out, "undefined")
	case .Circular:
		resize(out, start)
		append_ascii(out, "[Circular]")
	case .Refused:
		return .Not_Convertible_To_Json
	}
	return .None
}

// json_value writes v, and a value it opens: after each step, the value that step finished is
// settled into the frame on top (json_settle), and the frame moves on to its next value or closes.
@(private)
json_value :: proc(
	heap: ^gc.Heap,
	v: abi.Tagged,
	frames: ^[dynamic]Json_Frame,
	out: ^[dynamic]u16,
) -> Json_Result {
	result, opened := json_enter(heap, v, frames, out)
	for len(frames) > 0 {
		if !opened {
			if result == .Circular || result == .Refused {
				return result
			}
			json_settle(&frames[len(frames) - 1], result, out)
		}
		child, has_child := json_next(heap, &frames[len(frames) - 1], out)
		if !has_child {
			frame := pop(frames)
			append(out, ']' if frame.table.kind == .Array else '}')
			result, opened = .Written, false
			continue
		}
		result, opened = json_enter(heap, child, frames, out)
	}
	return result
}

// json_enter writes a value that has no parts, and opens a frame for an object or an array.
@(private)
json_enter :: proc(
	heap: ^gc.Heap,
	v: abi.Tagged,
	frames: ^[dynamic]Json_Frame,
	out: ^[dynamic]u16,
) -> (
	result: Json_Result,
	opened: bool,
) {
	switch v.tag {
	case .Undefined, .Function:
		return .Nothing, false
	case .Null:
		append_ascii(out, "null")
	case .Boolean:
		append_ascii(out, "true" if v.payload.boolean else "false")
	case .Number:
		n := v.payload.number
		if math.is_nan(n) || math.is_inf(n) {
			append_ascii(out, "null")
		} else {
			// Number::toString, so -0 is 0.
			buf: [num.STRING_MAX]byte
			append_ascii(out, num.to_string(buf[:], n))
		}
	case .String:
		json_quote(str.units((^abi.String_Cell)(v.payload.ref)), out)
	case .Object:
		cell := v.payload.ref
		for outer in frames {
			if outer.cell == cell {
				return .Circular, false
			}
		}
		table := gc.table_of(heap, cell)
		if table.kind == .Array {
			append(out, '[')
		} else {
			if _, found := value.own_method(heap, cell, "toJSON"); found {
				return .Refused, false
			}
			append(out, '{')
		}
		append(frames, Json_Frame{cell = cell, table = table, first = true})
		return .Written, true
	}
	return .Written, false
}

// json_settle takes in the value just written in a frame: nothing is null in an array, and takes
// its key back out of an object.
@(private)
json_settle :: proc(frame: ^Json_Frame, result: Json_Result, out: ^[dynamic]u16) {
	switch {
	case result == .Nothing && frame.table.kind == .Array:
		append_ascii(out, "null")
	case result == .Nothing:
		resize(out, frame.mark)
	case frame.table.kind == .Object:
		frame.first = false
	}
}

// json_next writes the separator, and for an object the key, of the frame's next value and answers
// that value; has_child is false once there is none.
@(private)
json_next :: proc(
	heap: ^gc.Heap,
	frame: ^Json_Frame,
	out: ^[dynamic]u16,
) -> (
	child: abi.Tagged,
	has_child: bool,
) {
	if frame.table.kind == .Array {
		array := (^abi.Array_Cell)(frame.cell)
		if frame.next >= array.length {
			return {}, false
		}
		if frame.next > 0 {
			append(out, ',')
		}
		kind := frame.table.element
		slot := &([^]byte)(array.elements)[frame.next * abi.SLOT_SIZE[kind]]
		child = value.load(heap, slot, kind)
		frame.next += 1
		return child, true
	}
	for frame.next < len(frame.table.fields) {
		field := frame.table.fields[frame.next]
		frame.next += 1
		v, present := value.field(heap, frame.cell, field)
		if !present {
			continue
		}
		frame.mark = len(out)
		if !frame.first {
			append(out, ',')
		}
		json_quote(key_units(field.name), out)
		append(out, ':')
		return v, true
	}
	return {}, false
}

// json_quote is QuoteJSONString: the short escapes, \u00XX for the other control characters, and
// \uXXXX for an unpaired surrogate.
@(private)
json_quote :: proc(text: string16, out: ^[dynamic]u16) {
	append(out, '"')
	for i := 0; i < len(text); i += 1 {
		unit := text[i]
		switch unit {
		case '"':
			append_ascii(out, "\\\"")
		case '\\':
			append_ascii(out, "\\\\")
		case '\b':
			append_ascii(out, "\\b")
		case '\f':
			append_ascii(out, "\\f")
		case '\n':
			append_ascii(out, "\\n")
		case '\r':
			append_ascii(out, "\\r")
		case '\t':
			append_ascii(out, "\\t")
		case 0 ..< 0x20:
			append_ascii(out, "\\u00")
			append(out, '0' + unit >> 4)
			append_hex(out, unit & 0xf)
		case 0xd800 ..= 0xdfff:
			if is_pair(text, i) {
				append(out, unit, text[i + 1])
				i += 1
			} else {
				append_ascii(out, "\\u")
				append_hex(out, unit)
			}
		case:
			append(out, unit)
		}
	}
	append(out, '"')
}
