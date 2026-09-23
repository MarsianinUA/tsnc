/*
Writes the width table of package console from five files of the Unicode Character Database:

	odin run src/runtime/console/tools -- <ucd dir> src/runtime/console/width_tables.odin

<ucd dir> holds EastAsianWidth.txt, UnicodeData.txt and DerivedNormalizationProps.txt,
emoji-data.txt from the emoji directory and DerivedGeneralCategory.txt from the extracted
directory, all of one version and side by side, from https://www.unicode.org/Public/<version>/ucd/.
They are read here and never committed.

The width of a code point is Node's GetColumnWidth (src/node_i18n.cc) with ambiguous characters
narrow: East_Asian_Width F or W is 2; A or N with Emoji_Presentation is 2; otherwise a Cc, Cf, Me
or Mn character other than U+00AD, or an Emoji_Modifier, is 0; everything else is 1. Node counts
the NFC form of a text, and a code point excluded from composition stays decomposed there even on
its own, so such a code point takes the width of its canonical decomposition: U+1D15E, a half note,
is the note head and the stem, 2 columns. The table holds the runs of 0, 2 and 3. Nothing is
freed: the program exits once the file is written.
*/
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

CODE_POINTS :: 0x110000

// Run matches console.Width_Run.
Run :: struct {
	first, last: rune,
	width:       u8,
}

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: generate_width_tables <ucd dir> <output file>")
		os.exit(2)
	}
	dir, output := os.args[1], os.args[2]

	widths_file := read_lines(dir, "EastAsianWidth.txt")
	categories_file := read_lines(dir, "DerivedGeneralCategory.txt")
	normalization_file := read_lines(dir, "DerivedNormalizationProps.txt")
	emoji_file := read_lines(dir, "emoji-data.txt")
	version := read_version(widths_file[0], "EastAsianWidth")
	others := [?][2]string {
		{categories_file[0], "DerivedGeneralCategory"},
		{normalization_file[0], "DerivedNormalizationProps"},
	}
	for other in others {
		if found := read_version(other[0], other[1]); found != version {
			fail("%s.txt is %s, EastAsianWidth.txt is %s", other[1], found, version)
		}
	}

	// The file gives every code point it does not list N, as its @missing line says.
	east_asian := make([]string, CODE_POINTS)
	for &value in east_asian {
		value = "N"
	}
	read_values(widths_file, "EastAsianWidth.txt", east_asian)
	categories := make([]string, CODE_POINTS)
	for &value in categories {
		value = "Cn"
	}
	read_values(categories_file, "DerivedGeneralCategory.txt", categories)
	emoji := make([]string, CODE_POINTS)
	read_values(emoji_file, "emoji-data.txt", emoji, "Emoji_Presentation")
	modifier := make([]string, CODE_POINTS)
	read_values(emoji_file, "emoji-data.txt", modifier, "Emoji_Modifier")
	excluded := make([]string, CODE_POINTS)
	read_values(
		normalization_file,
		"DerivedNormalizationProps.txt",
		excluded,
		"Full_Composition_Exclusion",
	)
	decompositions := read_decompositions(read_lines(dir, "UnicodeData.txt"))

	widths := make([]u8, CODE_POINTS)
	for code in 0 ..< CODE_POINTS {
		presentation, is_modifier := emoji[code] != "", modifier[code] != ""
		widths[code] = column_width(
			rune(code),
			east_asian[code],
			categories[code],
			presentation,
			is_modifier,
		)
	}
	// After every plain width is known, since a decomposition may name a later code point.
	nfc_widths := make([]u8, CODE_POINTS)
	copy(nfc_widths, widths)
	for code in 0 ..< CODE_POINTS {
		if excluded[code] != "" && decompositions[code] != nil {
			nfc_widths[code] = decomposed_width(rune(code), decompositions, widths)
		}
	}

	runs: [dynamic]Run
	for width, code in nfc_widths {
		if width == 1 {
			continue
		}
		if len(runs) > 0 {
			last := &runs[len(runs) - 1]
			if last.width == width && last.last == rune(code) - 1 {
				last.last = rune(code)
				continue
			}
		}
		append(&runs, Run{rune(code), rune(code), width})
	}

	b: strings.Builder
	write_table(&b, version, runs[:])
	if err := os.write_entire_file(output, strings.to_string(b)); err != nil {
		fail("cannot write %s: %s", output, os.error_string(err))
	}
}

// read_decompositions answers the canonical decomposition of every code point that has one, field
// 5 of UnicodeData.txt without a <tag>.
read_decompositions :: proc(lines: []string) -> [][]rune {
	decompositions := make([][]rune, CODE_POINTS)
	for line in lines {
		fields := strings.split(strings.trim_right(line, "\r"), ";")
		if len(fields) != 15 {
			fail("UnicodeData.txt: %d fields in %q", len(fields), line)
		}
		if fields[5] == "" || fields[5][0] == '<' {
			continue
		}
		parts := strings.fields(fields[5])
		mapping := make([]rune, len(parts))
		for part, i in parts {
			mapping[i] = parse_code_point(part)
		}
		decompositions[parse_code_point(fields[0])] = mapping
	}
	return decompositions
}

// decomposed_width is the width of the full canonical decomposition of `code`.
decomposed_width :: proc(code: rune, decompositions: [][]rune, widths: []u8) -> u8 {
	if decompositions[code] == nil {
		return widths[code]
	}
	total: u8
	for part in decompositions[code] {
		total += decomposed_width(part, decompositions, widths)
	}
	return total
}

column_width :: proc(
	code: rune,
	east_asian, category: string,
	presentation, modifier: bool,
) -> u8 {
	switch east_asian {
	case "F", "W":
		return 2
	case "A", "N":
		if presentation {
			return 2
		}
	case "H", "Na":
	case:
		fail("East_Asian_Width %q of %04X", east_asian, code)
	}
	// SOFT HYPHEN is a format character a terminal still shows.
	if code == 0x00ad {
		return 1
	}
	switch category {
	case "Cc", "Cf", "Me", "Mn":
		return 0
	}
	return 0 if modifier else 1
}

read_lines :: proc(dir, name: string) -> []string {
	path := strings.concatenate({dir, "/", name})
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fail("cannot read %s: %s", path, os.error_string(err))
	}
	return strings.split_lines(strings.trim_right(string(data), "\r\n"))
}

// read_version takes the version from the first line, "# EastAsianWidth-17.0.0.txt".
read_version :: proc(first_line, file: string) -> string {
	prefix := strings.concatenate({"# ", file, "-"})
	line := strings.trim_right(first_line, "\r")
	if !strings.has_prefix(line, prefix) || !strings.has_suffix(line, ".txt") {
		fail("%s.txt does not open with its version: %q", file, line)
	}
	return line[len(prefix):len(line) - len(".txt")]
}

// read_values stores the value of every line "0041..005A ; Na # ..." into `values`, or, when
// `only` names a property, the lines of that property.
read_values :: proc(lines: []string, file: string, values: []string, only := "") {
	found := false
	for line in lines {
		data, _, _ := strings.partition(strings.trim_right(line, "\r"), "#")
		codes, separator, value_text := strings.partition(data, ";")
		if separator == "" {
			continue
		}
		value := strings.trim_space(value_text)
		if only != "" && value != only {
			continue
		}
		first_text, _, last_text := strings.partition(strings.trim_space(codes), "..")
		first := parse_code_point(first_text)
		last := first if last_text == "" else parse_code_point(last_text)
		if last < first {
			fail("%s: a reversed range in %q", file, line)
		}
		for code in first ..= last {
			values[code] = value
		}
		found = true
	}
	if !found {
		fail("%s: no %s lines", file, only if only != "" else "data")
	}
}

write_table :: proc(b: ^strings.Builder, version: string, runs: []Run) {
	fmt.sbprintf(
		b,
		`// Generated from the Unicode Character Database %s; do not edit. Regenerate with
//
//	odin run src/runtime/console/tools -- <ucd dir> src/runtime/console/width_tables.odin

package console

@(private, rodata)
WIDTH_RUNS := [?]Width_Run {{
`,
		version,
	)
	for r in runs {
		fmt.sbprintf(b, "\t{{0x%04x, 0x%04x, %d}},\n", u32(r.first), u32(r.last), r.width)
	}
	strings.write_string(b, "}\n")
}

parse_code_point :: proc(text: string) -> rune {
	trimmed := strings.trim_space(text)
	value, ok := strconv.parse_u64_of_base(trimmed, 16)
	if !ok || len(trimmed) < 4 || value > 0x10ffff {
		fail("%q is not a code point", text)
	}
	return rune(value)
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}
