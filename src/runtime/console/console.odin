/*
Console output for console.log (requirements 3.9). A TS string is UTF-16 and the console gets UTF-8:
io.write_string16 re-encodes it and turns an unpaired surrogate into U+FFFD, as Node does.

The bytes are UTF-8 whatever the console code page: on Windows the Odin entry point, which the
runtime owns, switches the console to UTF-8 before tsnc_main runs.
*/
package console

import "core:bufio"
import "core:io"
import "core:os"

import "../../abi"

// write_line writes the cell's UTF-16 units as UTF-8, then a newline.
write_line :: proc(w: io.Writer, text: ^abi.String_Cell) -> io.Error {
	io.write_string16(w, units(text)) or_return
	return io.write_byte(w, '\n')
}

// log_string writes one line to stdout. The line goes out before the call returns, so lines on
// stdout and stderr keep the order of the calls.
log_string :: proc(text: ^abi.String_Cell) {
	buf: [4096]byte
	stdout: bufio.Writer
	bufio.writer_init_with_buf(&stdout, os.to_writer(os.stdout), buf[:])
	// Like C stdio and Go's fmt.Println, a failed write to stdout does not stop the program.
	_ = write_line(bufio.writer_to_writer(&stdout), text)
	_ = bufio.writer_flush(&stdout)
}

// direct: reads the cell layout here while console is the only reader; the view moves to package
// str with the rest of the string operations (T5.3).
@(private)
units :: proc(text: ^abi.String_Cell) -> string16 {
	return string16(([^]u16)(&text.units)[:text.length])
}
