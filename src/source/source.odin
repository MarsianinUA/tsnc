/*
Source files and positions in them. Later phases point into source text with a Span, a byte range
in one file, and a diagnostic turns the start of its span into a line and a column.

The file table is a []File indexed by File_ID. driver builds it: it reads each file, strips a UTF-8
byte order mark, normalizes the path and assigns File_ID values in breadth-first import order, with
the lib file as 0. This package does not touch the file system.

Line and column rules, shared by diagnostics (`file:line:col`) and abi.Fail_Site:
- Both are 1-based.
- A line ends at an ECMAScript line terminator, the set tsc counts: \n, \r\n (one break), a lone
  \r, U+2028 and U+2029.
- A column counts UTF-16 code units from the start of the line, as tsc and VS Code do. A tab is
  one unit, a code point above U+FFFF is two (a surrogate pair), an invalid UTF-8 byte is one (it
  reads as U+FFFD). ASCII and Cyrillic get one column per character.
*/
package source

import "core:slice"

// File_ID indexes the file table.
File_ID :: distinct u32

// MAX_FILE_SIZE is the largest text make_file accepts, in bytes. It keeps every offset, line and
// column within i32.
MAX_FILE_SIZE :: int(max(i32))

// Span is the byte range [start, end) of the text of `file`.
Span :: struct {
	file:  File_ID,
	start: i32,
	end:   i32,
}

File :: struct {
	path:        string, // borrowed; normalized by driver, one spelling per file; printed as is
	text:        string, // borrowed; UTF-8 without a byte order mark
	line_starts: []i32, // owned; byte offset of each line start, [0] == 0; read through position
}

// Position is 1-based; column counts UTF-16 code units (see the package doc).
Position :: struct {
	line:   i32,
	column: i32,
}

// make_file records where the lines of text start. Only line_starts is allocated, with allocator;
// path and text stay borrowed and must outlive the File.
make_file :: proc(path, text: string, allocator := context.allocator) -> File {
	ensure(len(text) <= MAX_FILE_SIZE)

	line_count := 1
	for i := 0; i < len(text); {
		size := line_terminator_size(text, i)
		i += max(size, 1)
		if size > 0 {
			line_count += 1
		}
	}

	line_starts := make([]i32, line_count, allocator)
	line := 1
	for i := 0; i < len(text); {
		size := line_terminator_size(text, i)
		i += max(size, 1)
		if size > 0 {
			line_starts[line] = i32(i)
			line += 1
		}
	}
	return {path = path, text = text, line_starts = line_starts}
}

// position turns a byte offset into file.text into a line and a column. offset lies on a character
// boundary in [0, len(file.text)]; the end of the text is a valid position.
position :: proc(file: File, offset: i32) -> Position {
	assert(0 <= offset && int(offset) <= len(file.text))

	// The line is the last one that starts at or before offset.
	index, found := slice.binary_search(file.line_starts, offset)
	line := index if found else index - 1

	column := 1
	for r in file.text[file.line_starts[line]:offset] {
		column += 2 if r > 0xFFFF else 1
	}
	return {line = i32(line + 1), column = i32(column)}
}

// line_terminator_size is the length in bytes of the line terminator that starts at text[i], with
// \r\n counted as one, or 0 if there is none or i is past the end. It is the one definition of a
// line break: tokenize reads it for automatic semicolon insertion, so a line there is the line
// that a diagnostic's position counts.
line_terminator_size :: proc(text: string, i: int) -> int {
	if i >= len(text) {
		return 0
	}
	switch text[i] {
	case '\n':
		return 1
	case '\r':
		has_newline := i + 1 < len(text) && text[i + 1] == '\n'
		return 2 if has_newline else 1
	case 0xE2:
		// U+2028 is E2 80 A8, U+2029 is E2 80 A9.
		if i + 2 < len(text) && text[i + 1] == 0x80 {
			last := text[i + 2]
			return 3 if last == 0xA8 || last == 0xA9 else 0
		}
	}
	return 0
}
