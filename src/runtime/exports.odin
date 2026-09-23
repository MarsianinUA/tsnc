package rt

import "base:runtime"
import "core:os"

import "../abi"
import "console"
import "fail"
import "num"
import "str"
import "value"

// One export per abi.Runtime_Proc; add the export together with the row.
#assert(len(abi.Runtime_Proc) == 28)

// Generated code only needs these symbols to be external, and nothing imports them from the
// executable, so they are kept with `require` and strong linkage rather than `@(export)`. That is
// dllexport on Windows: the executable got an export table, lld-link wrote the output's file name
// into it, and the name is the temporary one with a process id, so no two builds were alike.

// Every returning export starts the same way: its own context, then a temp arena guard that
// rewinds the scratch memory to where it was on entry. A rewind rather than a reset keeps an outer
// export's scratch intact when generated code calls back in, as the array sort comparator will.
// The three Math exports do no allocating of their own, and they still take a context, because an
// export that skipped it would be the one place a later assert inside it had nowhere to go.

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Console_String].symbol)
console_string :: proc "c" (err: b64, text: ^abi.String_Cell) {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	console.write_string(bool(err), text)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Console_Number].symbol)
console_number :: proc "c" (err: b64, value: f64) {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	console.write_number(bool(err), value)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Console_Boolean].symbol)
console_boolean :: proc "c" (err: b64, value: b64) {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	console.write_boolean(bool(err), bool(value))
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Log_String].symbol)
log_string :: proc "c" (text: ^abi.String_Cell) {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	console.log_string(text)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Math_Round].symbol)
math_round :: proc "c" (x: f64) -> f64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return num.round(x)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Math_Max].symbol)
math_max :: proc "c" (a, b: f64) -> f64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return num.max(a, b)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Math_Min].symbol)
math_min :: proc "c" (a, b: f64) -> f64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return num.min(a, b)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.String_Concat].symbol)
string_concat :: proc "c" (a, b: ^abi.String_Cell) -> ^abi.String_Cell {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return str.concat(&heap, a, b)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.String_Equal].symbol)
string_equal :: proc "c" (a, b: ^abi.String_Cell) -> b64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return b64(str.equal(a, b))
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.String_Less].symbol)
string_less :: proc "c" (a, b: ^abi.String_Cell) -> b64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return b64(str.compare(a, b) < 0)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.String_At].symbol)
string_at :: proc "c" (text: ^abi.String_Cell, index: f64) -> ^abi.String_Cell {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return str.unit_at(&heap, text, index)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.String_Char_Code_At].symbol)
string_char_code_at :: proc "c" (text: ^abi.String_Cell, position: f64) -> f64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return str.char_code_at(text, position)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.String_Slice].symbol)
string_slice :: proc "c" (text: ^abi.String_Cell, start, end: f64) -> ^abi.String_Cell {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return str.slice(&heap, text, start, end)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.String_Index_Of].symbol)
string_index_of :: proc "c" (text, search: ^abi.String_Cell, position: f64) -> f64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return f64(str.index_of(text, search, position))
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.String_Starts_With].symbol)
string_starts_with :: proc "c" (text, search: ^abi.String_Cell, position: f64) -> b64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return b64(str.starts_with(text, search, position))
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.String_Ends_With].symbol)
string_ends_with :: proc "c" (text, search: ^abi.String_Cell, end: f64) -> b64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return b64(str.ends_with(text, search, end))
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.String_Trim].symbol)
string_trim :: proc "c" (text: ^abi.String_Cell) -> ^abi.String_Cell {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return str.trim(&heap, text)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.String_To_Upper].symbol)
string_to_upper :: proc "c" (text: ^abi.String_Cell) -> ^abi.String_Cell {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return str.to_upper(&heap, text)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.String_To_Lower].symbol)
string_to_lower :: proc "c" (text: ^abi.String_Cell) -> ^abi.String_Cell {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return str.to_lower(&heap, text)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Number_To_String].symbol)
number_to_string :: proc "c" (value: f64) -> ^abi.String_Cell {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return str.from_number(&heap, value)
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Number_To_Fixed].symbol)
number_to_fixed :: proc "c" (value, digits: f64) -> ^abi.String_Cell {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	text, ok := str.to_fixed(&heap, value, digits)
	if !ok {
		// A RangeError in Node, which ends the process the way process_exit's does.
		fail.at({error = .Fraction_Digits_Out_Of_Range})
	}
	return text
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Number_Parse_Float].symbol)
number_parse_float :: proc "c" (text: ^abi.String_Cell) -> f64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return str.parse_float(text)
}

// A tagged value arrives as its two words (abi.C_Type.Tagged). The payload is a u64 rather than an
// abi.Payload, since how a C ABI passes a union of a double and a pointer is each target's guess,
// and how it passes an integer is not.

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Value_Typeof].symbol)
value_typeof :: proc "c" (tag: abi.Tag, payload: u64) -> ^abi.String_Cell {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return value.typeof_word(tagged(tag, payload))
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Value_Equal].symbol)
value_equal :: proc "c" (a_tag: abi.Tag, a_payload: u64, b_tag: abi.Tag, b_payload: u64) -> b64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return b64(value.equal(tagged(a_tag, a_payload), tagged(b_tag, b_payload)))
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Value_To_Boolean].symbol)
value_to_boolean :: proc "c" (tag: abi.Tag, payload: u64) -> b64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return b64(value.to_boolean(tagged(tag, payload)))
}

@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Value_To_String].symbol)
value_to_string :: proc "c" (tag: abi.Tag, payload: u64) -> ^abi.String_Cell {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	text, ok := value.to_string(&heap, tagged(tag, payload))
	if !ok {
		fail.at({error = .Not_Convertible_To_String})
	}
	return text
}

@(private)
tagged :: proc "contextless" (tag: abi.Tag, payload: u64) -> abi.Tagged {
	return {tag = tag, payload = transmute(abi.Payload)payload}
}

// No temp guard below: the process ends inside. The rows tell codegen the same through `diverges`.

#assert(abi.RUNTIME_EXPORTS[.Process_Exit].diverges)
@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Process_Exit].symbol)
process_exit :: proc "c" (code: f64) -> ! {
	context = export_context()
	exit, ok := num.exit_code(code)
	if !ok {
		// Node throws a RangeError, and v1 has no exceptions: the failure ends the process with
		// the code 1 an uncaught one ends Node with. The export is not told where the call
		// stands, so the line names no place.
		fail.at({error = .Exit_Code_Not_Integer})
	}
	os.exit(exit)
}

#assert(abi.RUNTIME_EXPORTS[.Fail].diverges)
@(require, linkage = "strong", link_name = abi.RUNTIME_EXPORTS[.Fail].symbol)
fail_at :: proc "c" (site: ^abi.Fail_Site) -> ! {
	context = export_context()
	fail.at(site^)
}
