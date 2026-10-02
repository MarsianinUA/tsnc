#+build linux, darwin
package rt

import "base:runtime"
import "core:sys/posix"

import "fail"

// The handler runs on a stack of its own, since the thread's is used up.
@(private)
HANDLER_STACK :: 64 * 1024

// Linux keeps 256 pages free below a growing stack (stack_guard_gap), so an overflow may fault
// that far past the limit.
@(private)
GUARD_GAP :: 1024 * 1024

@(private)
catch_stack_overflow :: proc() {
	// mmap rather than an allocation: LeakSanitizer would report a block nothing points to.
	stack := posix.mmap(nil, HANDLER_STACK, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	if stack == posix.MAP_FAILED {
		return
	}
	alternate := posix.stack_t {
		ss_sp   = stack,
		ss_size = HANDLER_STACK,
	}
	if posix.sigaltstack(&alternate, nil) != .OK {
		return
	}
	action := posix.sigaction_t {
		sa_sigaction = on_fault,
		sa_flags     = {.SIGINFO, .ONSTACK, .RESETHAND},
	}
	posix.sigaction(.SIGSEGV, &action, nil)
	// macOS reports a touch of the guard page as SIGBUS.
	posix.sigaction(.SIGBUS, &action, nil)
}

// A fault below the stack, within its limit, is an overflow. Any other one is left as it was:
// RESETHAND restored the default action, so the instruction faults again and the signal ends the
// process, as Rust does.
@(private)
on_fault :: proc "c" (_: posix.Signal, info: ^posix.siginfo_t, _: rawptr) {
	limit: posix.rlimit
	if posix.getrlimit(.STACK, &limit) != .OK {
		return
	}
	// The limit may be RLIM_INFINITY: the sum must not wrap.
	reach := max(limit.rlim_cur, limit.rlim_cur + GUARD_GAP)
	base, address := uintptr(heap.stack_base), uintptr(info.si_addr)
	if address >= base || posix.rlim_t(base - address) > reach {
		return
	}
	context = runtime.default_context()
	fail.at({error = .Stack_Overflow})
}
