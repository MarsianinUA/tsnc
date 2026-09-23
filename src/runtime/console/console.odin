/*
Console output for console.log and console.error (requirements 3.9), as Node prints it: the
arguments go through util.formatWithOptions (format.odin), which reads a format string in the first
one and hands every other value to util.inspect (inspect.odin), with the colors Node would use on
the same stream (color.odin). The line and its newline leave in one write, as in Node's
kWriteToConsole, so lines on stdout and stderr keep the order of the calls.

A TS string is UTF-16 and the console gets UTF-8, with an unpaired surrogate as U+FFFD, as Node
writes it. The bytes are UTF-8 whatever the console code page: on Windows the Odin entry point,
which the runtime owns, switches the console to UTF-8 before tsnc_main runs.

Everything a call builds lives in context.allocator, which is the export's scratch arena. Nothing
here allocates in the GC heap, so no collection runs while a line is formatted, and the runtime
keeps no state but the heap: the stream and the colors are decided at each call.
*/
package console

import "core:bufio"
import "core:io"
import "core:math"
import "core:os"

import "../../abi"
import "../fail"
import "../gc"
import "../num"
import "../str"

Stream :: enum u8 {
	Stdout, // console.log
	Stderr, // console.error
}

// log ends the program where Node would run code of the program to print a value, before any of
// the line is written.
log :: proc(heap: ^gc.Heap, stream: Stream, args: []abi.Tagged) {
	units := make([dynamic]u16, 0, 64)
	switch format(heap, args, should_colorize(stream), &units) {
	case .None:
	case .Not_Convertible_To_String:
		fail.at({error = .Not_Convertible_To_String})
	case .Not_Convertible_To_Number:
		fail.at({error = .Not_Convertible_To_Number})
	case .Not_Convertible_To_Json:
		fail.at({error = .Not_Convertible_To_Json})
	}
	append(&units, '\n')
	write_utf8(file_of(stream), units[:])
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

// write_line backs the Log_String row, which only the hand-built IR programs of the tests call.
write_line :: proc(w: io.Writer, text: ^abi.String_Cell) -> io.Error {
	io.write_string16(w, str.units(text)) or_return
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
file_of :: proc(stream: Stream) -> ^os.File {
	return os.stderr if stream == .Stderr else os.stdout
}

// write_utf8 writes a line longer than its buffer in pieces. Like C stdio and Go's fmt.Print, a
// failed write to the console does not stop the program.
@(private)
write_utf8 :: proc(file: ^os.File, units: []u16) {
	buf: [16 * 1024]byte
	at := 0
	for i := 0; i < len(units); i += 1 {
		if at > len(buf) - 4 {
			_, _ = os.write(file, buf[:at])
			at = 0
		}
		r := rune(units[i])
		switch {
		case r < 0x80:
			buf[at] = byte(r)
			at += 1
			continue
		case r < 0xd800 || r > 0xdfff:
		case r < 0xdc00 && i + 1 < len(units) && 0xdc00 <= units[i + 1] && units[i + 1] <= 0xdfff:
			r = 0x10000 + (r - 0xd800) << 10 + (rune(units[i + 1]) - 0xdc00)
			i += 1
		case:
			r = 0xfffd
		}
		switch {
		case r < 0x800:
			buf[at] = byte(0xc0 | r >> 6)
			buf[at + 1] = byte(0x80 | r & 0x3f)
			at += 2
		case r < 0x10000:
			buf[at] = byte(0xe0 | r >> 12)
			buf[at + 1] = byte(0x80 | r >> 6 & 0x3f)
			buf[at + 2] = byte(0x80 | r & 0x3f)
			at += 3
		case:
			buf[at] = byte(0xf0 | r >> 18)
			buf[at + 1] = byte(0x80 | r >> 12 & 0x3f)
			buf[at + 2] = byte(0x80 | r >> 6 & 0x3f)
			buf[at + 3] = byte(0x80 | r & 0x3f)
			at += 4
		}
	}
	_, _ = os.write(file, buf[:at])
}
