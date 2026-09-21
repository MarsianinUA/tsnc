/*
Console output for console.log and console.error (requirements 3.9). A TS string is UTF-16 and the
console gets UTF-8: io.write_string16 re-encodes it and turns an unpaired surrogate into U+FFFD, as
Node does.

The bytes are UTF-8 whatever the console code page: on Windows the Odin entry point, which the
runtime owns, switches the console to UTF-8 before tsnc_main runs.

One statement becomes several calls. The compiler knows every argument of a console.log statically,
so it picks a procedure per argument and writes the spaces between them and the line end as string
constants of its own; nothing here formats a list. The stream is a parameter for the same reason:
log and error differ only at the call site, and the runtime keeps no state but the GC heap.
*/
package console

import "core:bufio"
import "core:io"
import "core:math"
import "core:os"

import "../../abi"
import "../num"

write_string :: proc(err: bool, text: ^abi.String_Cell) {
	buf: [4096]byte
	out: bufio.Writer
	bufio.writer_init_with_buf(&out, os.to_writer(stream(err)), buf[:])
	// Like C stdio and Go's fmt.Print, a failed write to the console does not stop the program.
	_, _ = io.write_string16(bufio.writer_to_writer(&out), units(text))
	_ = bufio.writer_flush(&out)
}

write_boolean :: proc(err: bool, value: bool) {
	_, _ = os.write_string(stream(err), "true" if value else "false")
}

// write_number writes the digits of requirements 3.1. They are ASCII, so this path needs none of
// the UTF-16 re-encoding a string goes through.
write_number :: proc(err: bool, value: f64) {
	buf: [num.STRING_MAX]byte
	_, _ = os.write_string(stream(err), number_text(buf[:], value))
}

// number_text is what the console prints for a number: Number::toString, except that a negative
// zero keeps its sign. Node prints 0 for `${-0}` and -0 for console.log(-0), because a bare value
// goes through util.inspect and not through String. The rule is the console's, so num.to_string
// stays the conversion requirements 3.1 describes.
number_text :: proc(buf: []byte, value: f64) -> string {
	if value == 0 && math.sign_bit(value) {
		return string(buf[:copy(buf, "-0")])
	}
	return num.to_string(buf, value)
}

// write_line serves the hello world of T1.6, which codegen still builds by hand; T4.4 drops both.
write_line :: proc(w: io.Writer, text: ^abi.String_Cell) -> io.Error {
	io.write_string16(w, units(text)) or_return
	return io.write_byte(w, '\n')
}

// log_string sends the line out before the call returns, so lines on stdout and stderr keep the
// order of the calls.
log_string :: proc(text: ^abi.String_Cell) {
	buf: [4096]byte
	stdout: bufio.Writer
	bufio.writer_init_with_buf(&stdout, os.to_writer(os.stdout), buf[:])
	// Like C stdio and Go's fmt.Println, a failed write to stdout does not stop the program.
	_ = write_line(bufio.writer_to_writer(&stdout), text)
	_ = bufio.writer_flush(&stdout)
}

@(private)
stream :: proc(err: bool) -> ^os.File {
	return os.stderr if err else os.stdout
}

// direct: reads the cell layout here while console is the only reader; the view moves to package
// str with the rest of the string operations (T5.3).
@(private)
units :: proc(text: ^abi.String_Cell) -> string16 {
	return string16(([^]u16)(&text.units)[:text.length])
}
