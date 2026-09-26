package console

import "../../abi"
import "../arr"
import "../gc"
import "../num"
import "../str"
import "../value"

/*
util.formatWithOptions, formatWithOptionsInternal of lib/internal/util/inspect.js: a string first
argument is a format string while more arguments follow it, and every argument its specifiers did
not take is appended after a space, a string as it is and anything else through inspect.

	%s  String(), but a number keeps -0 and an object or an array is inspected to depth 0
	%d  Number()                  %i  parseInt(String())        %f  parseFloat(String())
	%j  JSON.stringify()          %o  inspect with hidden properties to depth 4
	%O  inspect                   %c  takes an argument and prints nothing
	%%  a percent sign, with or without arguments left

A specifier with no argument left stays as it is, and so does % before any other character.
*/

Format_Error :: enum u8 {
	None,
	Not_Convertible_To_String,
	Not_Convertible_To_Number,
	Not_Convertible_To_Json,
}

// DEPTH is util.inspect's default depth, which console.log keeps.
@(private)
DEPTH :: 2

// format stops at the first argument Node would run code of the program to print, and what it
// wrote of the line so far is then of no use.
format :: proc(
	heap: ^gc.Heap,
	args: []abi.Tagged,
	colors: bool,
	units: ^[dynamic]u16,
) -> Format_Error {
	options := Inspect_Options {
		depth  = DEPTH,
		colors = colors,
	}
	next := 0
	separate := false
	if len(args) > 0 && args[0].tag == .String {
		first := str.units((^abi.String_Cell)(args[0].payload.ref))
		if len(args) == 1 {
			append_units(units, first)
			return .None
		}
		last := 0
		for i := 0; i < len(first) - 1; i += 1 {
			if first[i] != '%' {
				continue
			}
			i += 1
			specifier := first[i]
			if next + 1 == len(args) {
				if specifier == '%' {
					append_units(units, first[last:i])
					last = i + 1
				}
				continue
			}
			switch specifier {
			case 's', 'j', 'd', 'O', 'o', 'i', 'f', 'c':
				append_units(units, first[last:i - 1])
				next += 1
				write_specifier(heap, specifier, args[next], options, units) or_return
				last = i + 1
			case '%':
				append_units(units, first[last:i])
				last = i + 1
			}
		}
		if last != 0 {
			next += 1
			separate = true
			append_units(units, first[last:])
		}
	}
	for v in args[next:] {
		if separate {
			append(units, ' ')
		}
		separate = true
		if v.tag == .String {
			append_units(units, str.units((^abi.String_Cell)(v.payload.ref)))
		} else {
			inspect(heap, v, options, units)
		}
	}
	return .None
}

@(private)
write_specifier :: proc(
	heap: ^gc.Heap,
	specifier: u16,
	v: abi.Tagged,
	options: Inspect_Options,
	units: ^[dynamic]u16,
) -> Format_Error {
	switch specifier {
	case 's':
		return write_string_specifier(heap, v, units)
	case 'j':
		return write_json(heap, v, units)
	case 'd':
		n := to_number(heap, v) or_return
		format_number(false, n, units)
	case 'O':
		inspect(heap, v, options, units)
	case 'o':
		inspect(heap, v, {depth = 4, colors = options.colors, show_hidden = true}, units)
	case 'i', 'f':
		text := make([dynamic]u16)
		if !arr.append_string(&text, heap, v) {
			return .Not_Convertible_To_String
		}
		ascii := ascii_prefix(text[:])
		n := num.parse_int(ascii) if specifier == 'i' else num.parse_float(ascii)
		format_number(false, n, units)
	case 'c':
	}
	return .None
}

// write_string_specifier is %s: String(v), except that a number keeps -0 and an object whose
// toString is the built-in one is inspected to depth 0, without colors.
@(private)
write_string_specifier :: proc(
	heap: ^gc.Heap,
	v: abi.Tagged,
	units: ^[dynamic]u16,
) -> Format_Error {
	switch v.tag {
	case .Number:
		format_number(false, v.payload.number, units)
	case .Object:
		if method, found := value.own_method(heap, v.payload.ref, "toString"); found {
			if method.tag == .Function {
				return .Not_Convertible_To_String
			}
		}
		inspect(heap, v, {depth = 0}, units)
	case .Undefined, .Null, .Boolean, .String, .Function:
		if !arr.append_string(units, heap, v) {
			return .Not_Convertible_To_String
		}
	}
	return .None
}

// to_number is Number(v) for %d. An object is converted by its valueOf and toString, and Node would
// call either one the object has of its own. A function is NaN: its source text is no number.
@(private)
to_number :: proc(heap: ^gc.Heap, v: abi.Tagged) -> (n: f64, err: Format_Error) {
	switch v.tag {
	case .Undefined, .Function:
		return NAN, .None
	case .Null:
		return 0, .None
	case .Boolean:
		return 1 if v.payload.boolean else 0, .None
	case .Number:
		return v.payload.number, .None
	case .String:
		return string_to_number(str.units((^abi.String_Cell)(v.payload.ref))), .None
	case .Object:
		table := gc.table_of(heap, v.payload.ref)
		if table.kind == .Object {
			_, has_value_of := value.own_method(heap, v.payload.ref, "valueOf")
			_, has_to_string := value.own_method(heap, v.payload.ref, "toString")
			if has_value_of || has_to_string {
				return 0, .Not_Convertible_To_Number
			}
			// "[object Object]"
			return NAN, .None
		}
		// An array's valueOf is the array itself, so its string, the elements joined, is read.
		text := make([dynamic]u16)
		if !arr.append_string(&text, heap, v) {
			return 0, .Not_Convertible_To_Number
		}
		return string_to_number(string16(text[:])), .None
	}
	unreachable()
}

@(private)
NAN :: f64(0h7ff8_0000_0000_0000)

// string_to_number is StringToNumber of a text in UTF-16. Past the whitespace around it, a numeric
// literal is ASCII, so any other unit makes it NaN.
@(private)
string_to_number :: proc(text: string16) -> f64 {
	from, to := 0, len(text)
	for from < to && num.is_whitespace(rune(text[from])) {
		from += 1
	}
	for to > from && num.is_whitespace(rune(text[to - 1])) {
		to -= 1
	}
	ascii := make([]byte, to - from)
	for unit, i in text[from:to] {
		if unit >= 0x80 {
			return NAN
		}
		ascii[i] = byte(unit)
	}
	return num.to_number(string(ascii))
}

// ascii_prefix is what parseInt and parseFloat can read of a text: past the leading whitespace,
// the units up to the first that is not ASCII, as neither reads any such unit.
@(private)
ascii_prefix :: proc(text: []u16) -> string {
	from := 0
	for from < len(text) && num.is_whitespace(rune(text[from])) {
		from += 1
	}
	to := from
	for to < len(text) && text[to] < 0x80 {
		to += 1
	}
	ascii := make([]byte, to - from)
	for unit, i in text[from:to] {
		ascii[i] = byte(unit)
	}
	return string(ascii)
}
