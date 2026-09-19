package source_tests

import "core:testing"

import "../../src/source"

Expected :: struct {
	offset:   i32,
	position: source.Position,
}

@(test)
crlf_is_one_line_break :: proc(t: ^testing.T) {
	expect_positions(t, "a\r\nb", {{1, {1, 2}}, {2, {1, 3}}, {3, {2, 1}}})
	// A Windows file: a Cyrillic line, an empty line, then code.
	expect_positions(
		t,
		"при\r\n\r\nlet x",
		{{6, {1, 4}}, {8, {2, 1}}, {10, {3, 1}}, {14, {3, 5}}},
	)
}

@(test)
every_line_terminator_starts_a_line :: proc(t: ^testing.T) {
	// \n, a lone \r, U+2028 and U+2029.
	expect_positions(
		t,
		"a\nb\rc d e",
		{{2, {2, 1}}, {4, {3, 1}}, {5, {3, 2}}, {8, {4, 1}}, {12, {5, 1}}},
	)
}

@(test)
line_terminator_size_reads_one_terminator :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		i:    int,
		size: int,
	}
	cases := []Case {
		{"\n", 0, 1},
		{"\r", 0, 1},
		{"\r\n", 0, 2},
		{"\r\n", 1, 1},
		{"a\xe2\x80\xa8", 1, 3}, // U+2028
		{"\xe2\x80\xa9", 0, 3}, // U+2029
		{"\xe2\x80\xaa", 0, 0}, // U+202A is no terminator
		{"\xe2\x80", 0, 0}, // cut short by the end of the text
		{"a", 0, 0},
		{"a", 1, 0}, // the end of the text
	}
	for c in cases {
		got := source.line_terminator_size(c.text, c.i)
		testing.expectf(t, got == c.size, "%q at %d: got %d, want %d", c.text, c.i, got, c.size)
	}
}

@(test)
empty_lines_keep_their_numbers :: proc(t: ^testing.T) {
	expect_positions(t, "a\n\n\nb", {{1, {1, 2}}, {2, {2, 1}}, {3, {3, 1}}, {4, {4, 1}}})
}

@(test)
end_of_text_is_a_position :: proc(t: ^testing.T) {
	expect_positions(t, "", {{0, {1, 1}}})
	expect_positions(t, "ab", {{2, {1, 3}}})
	expect_positions(t, "ab\n", {{3, {2, 1}}})
}

@(test)
column_counts_utf16_units :: proc(t: ^testing.T) {
	// Cyrillic: two bytes, one unit per letter.
	expect_positions(t, "const при = 1", {{10, {1, 9}}, {13, {1, 11}}})
	// A code point above U+FFFF: four bytes, two units.
	expect_positions(t, "\U0001F600x", {{4, {1, 3}}})
	expect_positions(t, "\tx", {{1, {1, 2}}})
	// An invalid byte reads as U+FFFD, one unit.
	expect_positions(t, "\xff=", {{1, {1, 2}}})
}

@(test)
make_file_borrows_path_and_text :: proc(t: ^testing.T) {
	text := "let x = 1\n"
	file := source.make_file("src/main.ts", text)
	defer delete(file.line_starts)

	testing.expect_value(t, file.path, "src/main.ts")
	testing.expect(t, raw_data(file.text) == raw_data(text), "text was copied")
}

expect_positions :: proc(
	t: ^testing.T,
	text: string,
	expected: []Expected,
	loc := #caller_location,
) {
	file := source.make_file("test.ts", text)
	defer delete(file.line_starts)

	for e in expected {
		got := source.position(file, e.offset)
		testing.expectf(
			t,
			got == e.position,
			"%q at offset %d: got %d:%d, want %d:%d",
			text,
			e.offset,
			got.line,
			got.column,
			e.position.line,
			e.position.column,
			loc = loc,
		)
	}
}
