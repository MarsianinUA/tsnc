package rt

import "base:runtime"
import win "core:sys/windows"

import "fail"

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	SetThreadStackGuarantee :: proc(StackSizeInBytes: ^win.ULONG) -> win.BOOL ---
}

// The stack the handler still has once the guard page is gone: Rust asks for 20 KiB, ASan's frames
// take more.
@(private)
HANDLER_STACK :: 64 * 1024

@(private)
catch_stack_overflow :: proc() {
	guarantee := win.ULONG(HANDLER_STACK)
	if !SetThreadStackGuarantee(&guarantee) {
		return
	}
	win.AddVectoredExceptionHandler(1, on_exception)
}

// Every other exception goes on to the next handler, ASan's among them.
@(private)
on_exception :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	if info.ExceptionRecord.ExceptionCode != win.EXCEPTION_STACK_OVERFLOW {
		return win.EXCEPTION_CONTINUE_SEARCH
	}
	context = runtime.default_context()
	fail.at({error = .Stack_Overflow})
}
