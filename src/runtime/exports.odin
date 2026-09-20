package rt

import "base:runtime"
import "core:os"

import "../abi"
import "console"
import "fail"
import "num"

// One export per abi.Runtime_Proc; add the export together with the row.
#assert(len(abi.Runtime_Proc) == 9)

// Every returning export starts the same way: its own context, then a temp arena guard that
// rewinds the scratch memory to where it was on entry. A rewind rather than a reset keeps an outer
// export's scratch intact when generated code calls back in, as the array sort comparator will.
// The three Math exports do no allocating of their own, and they still take a context, because an
// export that skipped it would be the one place a later assert inside it had nowhere to go.

@(export, link_name = abi.RUNTIME_EXPORTS[.Console_String].symbol)
console_string :: proc "c" (err: b64, text: ^abi.String_Cell) {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	console.write_string(bool(err), text)
}

@(export, link_name = abi.RUNTIME_EXPORTS[.Console_Number].symbol)
console_number :: proc "c" (err: b64, value: f64) {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	console.write_number(bool(err), value)
}

@(export, link_name = abi.RUNTIME_EXPORTS[.Console_Boolean].symbol)
console_boolean :: proc "c" (err: b64, value: b64) {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	console.write_boolean(bool(err), bool(value))
}

@(export, link_name = abi.RUNTIME_EXPORTS[.Log_String].symbol)
log_string :: proc "c" (text: ^abi.String_Cell) {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	console.log_string(text)
}

@(export, link_name = abi.RUNTIME_EXPORTS[.Math_Round].symbol)
math_round :: proc "c" (x: f64) -> f64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return num.round(x)
}

@(export, link_name = abi.RUNTIME_EXPORTS[.Math_Max].symbol)
math_max :: proc "c" (a, b: f64) -> f64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return num.max(a, b)
}

@(export, link_name = abi.RUNTIME_EXPORTS[.Math_Min].symbol)
math_min :: proc "c" (a, b: f64) -> f64 {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return num.min(a, b)
}

// No temp guard below: the process ends inside. The rows tell codegen the same through `diverges`.

#assert(abi.RUNTIME_EXPORTS[.Process_Exit].diverges)
@(export, link_name = abi.RUNTIME_EXPORTS[.Process_Exit].symbol)
process_exit :: proc "c" (code: f64) -> ! {
	context = export_context()
	os.exit(num.exit_code(code))
}

#assert(abi.RUNTIME_EXPORTS[.Fail].diverges)
@(export, link_name = abi.RUNTIME_EXPORTS[.Fail].symbol)
fail_at :: proc "c" (site: ^abi.Fail_Site) -> ! {
	context = export_context()
	fail.at(site^)
}
