package console

import "core:math"
import "core:unicode/utf16"

import "../../abi"
import "../gc"
import "../num"
import "../str"
import "../value"

/*
JSON.stringify of one value, for %j. Node answers "undefined" where JSON.stringify answers
undefined, for undefined itself and a function, and "[Circular]" for a value that contains itself,
where JSON.stringify throws.
*/

@(private)
Json_Result :: enum u8 {
	Written,
	Nothing, // undefined or a function: an array writes null there, an object leaves the key out
	Circular,
	Refused, // an own toJSON function, which Node would call
}

@(private)
write_json :: proc(heap: ^gc.Heap, v: abi.Tagged, out: ^[dynamic]u16) -> Format_Error {
	start := len(out)
	stack := make([dynamic]^abi.Cell_Header)
	switch json_value(heap, v, &stack, out) {
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

@(private)
json_value :: proc(
	heap: ^gc.Heap,
	v: abi.Tagged,
	stack: ^[dynamic]^abi.Cell_Header,
	out: ^[dynamic]u16,
) -> Json_Result {
	switch v.tag {
	case .Undefined, .Function:
		return .Nothing
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
		for outer in stack {
			if outer == cell {
				return .Circular
			}
		}
		append(stack, cell)
		defer pop(stack)
		table := gc.table_of(heap, cell)
		if table.kind == .Array {
			return json_array(heap, (^abi.Array_Cell)(cell), table.element, stack, out)
		}
		return json_object(heap, cell, table, stack, out)
	}
	return .Written
}

@(private)
json_array :: proc(
	heap: ^gc.Heap,
	array: ^abi.Array_Cell,
	kind: abi.Slot_Kind,
	stack: ^[dynamic]^abi.Cell_Header,
	out: ^[dynamic]u16,
) -> Json_Result {
	append(out, '[')
	size := abi.SLOT_SIZE[kind]
	for i in 0 ..< array.length {
		if i > 0 {
			append(out, ',')
		}
		element := value.load(heap, &([^]byte)(array.elements)[i * size], kind)
		switch json_value(heap, element, stack, out) {
		case .Written:
		case .Nothing:
			append_ascii(out, "null")
		case .Circular:
			return .Circular
		case .Refused:
			return .Refused
		}
	}
	append(out, ']')
	return .Written
}

@(private)
json_object :: proc(
	heap: ^gc.Heap,
	cell: ^abi.Cell_Header,
	table: abi.Type_Table,
	stack: ^[dynamic]^abi.Cell_Header,
	out: ^[dynamic]u16,
) -> Json_Result {
	if _, found := value.own_method(heap, cell, "toJSON"); found {
		return .Refused
	}
	append(out, '{')
	first := true
	for field in table.fields {
		v, present := value.field(heap, cell, field)
		if !present {
			continue
		}
		mark := len(out)
		if !first {
			append(out, ',')
		}
		key := make([]u16, len(field.name))
		json_quote(string16(key[:utf16.encode_string(key, field.name)]), out)
		append(out, ':')
		switch json_value(heap, v, stack, out) {
		case .Written:
			first = false
		case .Nothing:
			resize(out, mark)
		case .Circular:
			return .Circular
		case .Refused:
			return .Refused
		}
	}
	append(out, '}')
	return .Written
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
