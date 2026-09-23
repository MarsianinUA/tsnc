/*
Runtime errors. A failure writes one line to stderr and ends the process with exit code 1
(requirements 3.8):

	error: index out of range at main.ts:3:5
	error: out of memory

The location is left out when the failure has none. Nothing here allocates, so an out-of-memory
failure can be reported as well.

Known limitation: on Windows the Odin entry point switches the console to UTF-8 and restores the old
code page when main returns. os.exit ends the process at once, so after a failure the console stays
on UTF-8. Restoring it would need package-level state, and the runtime keeps that to the GC heap.
*/
package fail

import "base:runtime"
import "core:bufio"
import "core:io"
import "core:os"

import "../../abi"

write_message :: proc(w: io.Writer, site: abi.Fail_Site, detail: ..string) -> io.Error {
	io.write_string(w, "error: ") or_return
	io.write_string(w, error_name(site.error)) or_return
	for part in detail {
		io.write_string(w, ": ") or_return
		io.write_string(w, part) or_return
	}
	if site.file != "" {
		io.write_string(w, " at ") or_return
		io.write_string(w, site.file) or_return
		io.write_byte(w, ':') or_return
		io.write_int(w, int(site.line)) or_return
		io.write_byte(w, ':') or_return
		io.write_int(w, int(site.column)) or_return
	}
	return io.write_byte(w, '\n')
}

at :: proc(site: abi.Fail_Site, detail: ..string) -> ! {
	// An assertion inside the writes below must not come back here through assertion_failure.
	context.assertion_failure_proc = runtime.default_assertion_failure_proc

	buf: [512]byte
	stderr: bufio.Writer
	bufio.writer_init_with_buf(&stderr, os.to_writer(os.stderr), buf[:])
	// When stderr itself fails there is nobody left to tell: the exit code still says it.
	_ = write_message(bufio.writer_to_writer(&stderr), site, ..detail)
	_ = bufio.writer_flush(&stderr)
	os.exit(1)
}

// assertion_failure has the shape of runtime.Assertion_Failure_Proc. The runtime installs it in
// the context, so an assert or panic inside the runtime fails at its Odin source location.
assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	site := abi.Fail_Site {
		file   = loc.file_path,
		line   = loc.line,
		column = loc.column,
		error  = .Internal,
	}
	if message == "" {
		at(site, prefix)
	}
	at(site, prefix, message)
}

@(private)
error_name :: proc(error: abi.Runtime_Error) -> string {
	// Generated code builds Fail_Site constants, so a bad value is a compiler bug; name it
	// instead of tripping a bounds check on the way out.
	if error < min(abi.Runtime_Error) || error > max(abi.Runtime_Error) {
		return "unknown error"
	}
	return NAMES[error]
}

@(private, rodata)
NAMES := [abi.Runtime_Error]string {
	.Index_Out_Of_Range           = "index out of range",
	.Index_Not_Integer            = "index is not an integer",
	.Non_Null_Assertion           = "non-null assertion failed",
	.Type_Assertion               = "type assertion failed",
	.Out_Of_Memory                = "out of memory",
	.Internal                     = "internal error",
	.Exit_Code_Not_Integer        = "process.exit code is not an integer",
	.Fraction_Digits_Out_Of_Range = "toFixed() digits argument must be between 0 and 100",
	.Not_Convertible_To_String    = "tsnc cannot convert a function, or an object with its own toString, to a string",
}
