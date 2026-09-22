/*
The tsnc runtime, built on its own into an object file and linked with every compiled program:

	odin build src/runtime -build-mode:obj -use-single-module -out:dist/tsnc_rt-<target>.obj -vet -strict-style

Without -use-single-module an unoptimized build writes one object file per package.

The runtime owns the process entry. Odin's entry point sets up the context and, on Windows, the
UTF-8 console, then runs main, which calls the generated tsnc_main. Returning from main exits the
process with code 0; a runtime error exits with code 1 through package fail.

Generated code calls back into the runtime through the exports in exports.odin, one per
abi.Runtime_Proc. Generated code passes no Odin context, so each export builds its own first.
The subpackages are plain Odin; proc "c" lives only in this package.
*/
package rt

import "base:runtime"
import "core:os"

import "../abi"
import "fail"
import "gc"

foreign _ {
	@(link_name = abi.MAIN_SYMBOL)
	tsnc_main :: proc "c" () ---
	@(link_name = abi.TYPE_TABLES_SYMBOL)
	tsnc_type_tables :: proc "c" () -> ^[]abi.Type_Table ---
	@(link_name = abi.ROOTS_SYMBOL)
	tsnc_roots :: proc "c" () -> ^[]abi.Root ---
}

// heap is the one piece of state the runtime keeps. The exports reach it here, since generated code
// passes them no heap.
@(private)
heap: gc.Heap

// An environment variable, so that stress mode needs no rebuild (requirements 10).
@(private)
STRESS_VARIABLE :: "TSNC_GC_STRESS"

main :: proc() {
	context.assertion_failure_proc = fail.assertion_failure
	// Every frame of tsnc_main lies below this local, so its address is where the stack scan stops.
	stack_base: uintptr
	mode := gc.Heap_Mode.Normal
	if os.get_env(STRESS_VARIABLE, context.temp_allocator) == "1" {
		mode = .Stress
	}
	switch gc.heap_init(&heap, tsnc_type_tables()^, tsnc_roots()^, &stack_base, mode) {
	case .None:
	case .Out_Of_Memory:
		fail.at({error = .Out_Of_Memory})
	case .Bad_Table:
		fail.at({error = .Internal}, "malformed type table")
	case .Bad_Root:
		fail.at({error = .Internal}, "malformed root table")
	}
	tsnc_main()
}

// export_context makes the thread's temp arena the scratch arena of the call: the export rewinds
// it on return, so core code may allocate freely inside the call. The GC heap never becomes
// context.allocator (requirements 4.5).
@(private)
export_context :: proc "contextless" () -> runtime.Context {
	context = runtime.default_context()
	context.allocator = context.temp_allocator
	context.assertion_failure_proc = fail.assertion_failure
	return context
}
