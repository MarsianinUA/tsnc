package console_tests

import "core:mem"
import "core:strings"
import "core:testing"
import "core:unicode/utf16"

import "../../../src/abi"
import "../../../src/runtime/console"
import "../../../src/runtime/num"

// Expected output is spelled in UTF-8 bytes, not with the \u escapes of the input, so the test does
// not trust the same encoder twice.

@(test)
ascii_line :: proc(t: ^testing.T) {
	testing.expect_value(t, line(cell_from_text("hello")), "hello\n")
}

@(test)
empty_string_is_an_empty_line :: proc(t: ^testing.T) {
	testing.expect_value(t, line(cell_from_text("")), "\n")
}

@(test)
cyrillic_is_utf8 :: proc(t: ^testing.T) {
	text := cell_from_text("Привет")
	testing.expect_value(t, line(text), "\xd0\x9f\xd1\x80\xd0\xb8\xd0\xb2\xd0\xb5\xd1\x82\n")
}

@(test)
emoji_surrogate_pair_is_one_utf8_character :: proc(t: ^testing.T) {
	alone := cell_from_units({0xd83d, 0xde00})
	testing.expect_value(t, line(alone), "\xf0\x9f\x98\x80\n")

	inside := cell_from_text("a\U0001F600б")
	testing.expect_value(t, inside.length, 4) // a, the surrogate pair, b
	testing.expect_value(t, line(inside), "a\xf0\x9f\x98\x80\xd0\xb1\n")
}

// Node prints an unpaired surrogate as U+FFFD, the replacement character.
@(test)
unpaired_surrogate_is_replacement_character :: proc(t: ^testing.T) {
	testing.expect_value(t, line(cell_from_units({'a', 0xd83d})), "a\xef\xbf\xbd\n")
	testing.expect_value(t, line(cell_from_units({0xde00, 'b'})), "\xef\xbf\xbdb\n")
	testing.expect_value(t, line(cell_from_units({0xde00, 0xd83d})), "\xef\xbf\xbd\xef\xbf\xbd\n")
}

// A number reaches the console as the text of requirements 3.1, with the one exception Node makes:
// console.log(-0) prints the sign that String(-0) drops. The digits themselves are checked against
// Node in tests/runtime/num.
@(test)
a_negative_zero_keeps_its_sign_on_the_console :: proc(t: ^testing.T) {
	NEGATIVE_ZERO :: 0h8000_0000_0000_0000
	testing.expect_value(t, number(NEGATIVE_ZERO), "-0")
	testing.expect_value(t, number(0), "0")
	testing.expect_value(t, number(1.5), "1.5")
	testing.expect_value(t, number(1e21), "1e+21")
}

number :: proc(value: f64) -> string {
	buf: [num.STRING_MAX]byte
	return strings.clone(console.number_text(buf[:], value), context.temp_allocator)
}

line :: proc(text: ^abi.String_Cell) -> string {
	b := strings.builder_make(context.temp_allocator)
	err := console.write_line(strings.to_writer(&b), text)
	assert(err == nil)
	return strings.to_string(b)
}

cell_from_text :: proc(text: string) -> ^abi.String_Cell {
	// A UTF-8 string never has fewer bytes than UTF-16 units.
	units := make([]u16, len(text), context.temp_allocator)
	return cell_from_units(units[:utf16.encode_string(units, text)])
}

// cell_from_units lays out a string cell the way generated code does: the header, the length,
// then the units.
cell_from_units :: proc(units: []u16) -> ^abi.String_Cell {
	size := size_of(abi.String_Cell) + len(units) * size_of(u16)
	memory, err := mem.alloc(size, align_of(abi.String_Cell), context.temp_allocator)
	assert(err == nil)
	cell := (^abi.String_Cell)(memory)
	cell.type_table = abi.Type_Table_ID(abi.Builtin_Table.String)
	cell.length = len(units)
	copy(([^]u16)(&cell.units)[:len(units)], units)
	return cell
}
