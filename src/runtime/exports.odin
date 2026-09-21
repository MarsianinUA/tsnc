package rt

import "base:runtime"
import "core:os"

import "../abi"
import "console"
import "fail"
import "num"

// One export per abi.Runtime_Proc; add the export together with the row.
#assert(len(abi.Runtime_Proc) == 9)

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
