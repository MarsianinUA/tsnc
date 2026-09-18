package rt

import "base:runtime"

import "../abi"
import "console"
import "fail"

// One export per abi.Runtime_Proc; add the export together with the row.
#assert(len(abi.Runtime_Proc) == 2)

// Every returning export starts the same way: its own context, then a temp arena guard that
// rewinds the scratch memory to where it was on entry. A rewind rather than a reset keeps an outer
// export's scratch intact when generated code calls back in, as the array sort comparator will.

@(export, link_name = abi.RUNTIME_EXPORTS[.Log_String].symbol)
log_string :: proc "c" (text: ^abi.String_Cell) {
	context = export_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	console.log_string(text)
}

// No temp guard: the process ends inside.
@(export, link_name = abi.RUNTIME_EXPORTS[.Fail].symbol)
fail_at :: proc "c" (site: ^abi.Fail_Site) -> ! {
	context = export_context()
	fail.at(site^)
}
