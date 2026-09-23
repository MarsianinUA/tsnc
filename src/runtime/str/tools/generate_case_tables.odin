/*
Writes the case tables of package str from three files of the Unicode Character Database:

	odin run src/runtime/str/tools -- <ucd dir> src/runtime/str/case_tables.odin

<ucd dir> holds UnicodeData.txt, SpecialCasing.txt and DerivedCoreProperties.txt of one version,
from https://www.unicode.org/Public/<version>/ucd/. They are read here and never committed.

The runtime reads the tables without checking them, so every check lives here: a mapping the
runtime could not represent stops the generator before it reaches the output. Nothing is freed:
the program exits once the file is written.
*/
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

Mapping :: struct {
	from, to: rune,
}

// Run matches str.Case_Run: every code point of [first, last] whose distance from first is a
// multiple of step maps to itself plus delta.
Run :: struct {
	first, last: rune,
	delta:       i32,
	step:        i32,
}

// Special is one unconditional row of SpecialCasing.txt, the full mappings of one code point.
Special :: struct {
	code:         rune,
	lower, upper: []rune,
}

Range :: [2]rune

// SPECIAL_MAX is the length of str.Special_Case's arrays.
SPECIAL_MAX :: 3
SIGMA :: 0x03a3
// FINAL_SIGMA is what str.to_lower writes for the Final_Sigma row, which it applies itself.
FINAL_SIGMA :: 0x03c2

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: generate_case_tables <ucd dir> <output file>")
		os.exit(2)
	}
	dir, output := os.args[1], os.args[2]

	upper, lower := read_simple_mappings(read_lines(dir, "UnicodeData.txt"))
	special_lines := read_lines(dir, "SpecialCasing.txt")
	specials := read_special_casing(special_lines)
	properties := read_lines(dir, "DerivedCoreProperties.txt")
	version := read_version(properties[0], "DerivedCoreProperties")
	if other := read_version(special_lines[0], "SpecialCasing"); other != version {
		fail("SpecialCasing.txt is %s, DerivedCoreProperties.txt is %s", other, version)
	}
	cased := read_property(properties, "Cased")
	ignorable := read_property(properties, "Case_Ignorable")

	b: strings.Builder
	write_header(&b, version)
	write_runs(&b, "UPPER_RUNS", runs_of(upper))
	write_runs(&b, "LOWER_RUNS", runs_of(lower))
	write_specials(&b, specials)
	write_ranges(&b, "CASED", cased)
	write_ranges(&b, "CASE_IGNORABLE", ignorable)

	if err := os.write_entire_file(output, strings.to_string(b)); err != nil {
		fail("cannot write %s: %s", output, os.error_string(err))
	}
}

read_lines :: proc(dir, name: string) -> []string {
	path := strings.concatenate({dir, "/", name})
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fail("cannot read %s: %s", path, os.error_string(err))
	}
	return strings.split_lines(strings.trim_right(string(data), "\r\n"))
}

// read_version takes the version from the first line, "# DerivedCoreProperties-17.0.0.txt".
read_version :: proc(first_line, file: string) -> string {
	prefix := strings.concatenate({"# ", file, "-"})
	line := strings.trim_right(first_line, "\r")
	if !strings.has_prefix(line, prefix) || !strings.has_suffix(line, ".txt") {
		fail("%s.txt does not open with its version: %q", file, line)
	}
	return line[len(prefix):len(line) - len(".txt")]
}

// read_simple_mappings answers the simple uppercase and lowercase mappings of UnicodeData.txt,
// fields 12 and 13, in code point order.
read_simple_mappings :: proc(lines: []string) -> (upper, lower: []Mapping) {
	uppers, lowers: [dynamic]Mapping
	previous := rune(-1)
	for line in lines {
		fields := strings.split(strings.trim_right(line, "\r"), ";")
		if len(fields) != 15 {
			fail("UnicodeData.txt: %d fields in %q", len(fields), line)
		}
		code := parse_code_point(fields[0])
		if code <= previous {
			fail("UnicodeData.txt: %04X is out of order", code)
		}
		previous = code
		if fields[12] != "" {
			append(&uppers, Mapping{code, parse_code_point(fields[12])})
		}
		if fields[13] != "" {
			append(&lowers, Mapping{code, parse_code_point(fields[13])})
		}
	}
	return uppers[:], lowers[:]
}

// read_special_casing keeps the unconditional rows. A row with a language in its conditions is
// skipped, since toUpperCase and toLowerCase are the locale-independent mappings. The one
// context-dependent row allowed is Final_Sigma on U+03A3, which str.to_lower applies itself.
read_special_casing :: proc(lines: []string) -> []Special {
	specials: [dynamic]Special
	for line in lines {
		data, _, _ := strings.partition(strings.trim_right(line, "\r"), "#")
		if strings.trim_space(data) == "" {
			continue
		}
		fields := strings.split(data, ";")
		// code; lower; title; upper; then an optional condition list, and the trailing ";".
		if len(fields) != 5 && len(fields) != 6 {
			fail("SpecialCasing.txt: %d fields in %q", len(fields), line)
		}
		code := parse_code_point(fields[0])
		if len(fields) == 6 {
			conditions := strings.fields(fields[4])
			if len(conditions) == 0 {
				fail("SpecialCasing.txt: an empty condition list in %q", line)
			}
			if is_language(conditions[0]) {
				continue
			}
			only_final_sigma := len(conditions) == 1 && conditions[0] == "Final_Sigma"
			if code == SIGMA && only_final_sigma && parse_code_point(fields[1]) == FINAL_SIGMA {
				continue
			}
			fail("SpecialCasing.txt: the runtime has no rule for %q", line)
		}
		// str.write_case tells a row that maps to itself by comparing it with {u16(r), 0, 0}.
		if code > 0xffff {
			fail("SpecialCasing.txt: %04X has a row and is no BMP character", code)
		}
		lower := full_mapping(code, fields[1])
		upper := full_mapping(code, fields[3])
		append(&specials, Special{code, lower, upper})
	}
	slice.sort_by(specials[:], proc(a, b: Special) -> bool {return a.code < b.code})
	for i in 1 ..< len(specials) {
		if specials[i].code == specials[i - 1].code {
			fail("SpecialCasing.txt: two unconditional rows for %04X", specials[i].code)
		}
	}
	return specials[:]
}

// A language is a lowercase tag such as "lt" or "tr"; a context starts with a capital, as in
// "Final_Sigma" or "After_I".
is_language :: proc(condition: string) -> bool {
	return 'a' <= condition[0] && condition[0] <= 'z'
}

// full_mapping checks what str.Special_Case can hold: at most SPECIAL_MAX units, each in the BMP
// and none of them U+0000, which pads the arrays.
full_mapping :: proc(code: rune, field: string) -> []rune {
	parts := strings.fields(field)
	if len(parts) == 0 || len(parts) > SPECIAL_MAX {
		fail("SpecialCasing.txt: %04X maps to %d code points", code, len(parts))
	}
	mapping := make([]rune, len(parts))
	for part, i in parts {
		to := parse_code_point(part)
		if to == 0 || to > 0xffff || is_surrogate(to) {
			fail("SpecialCasing.txt: %04X maps to %04X, which is no BMP character", code, to)
		}
		mapping[i] = to
	}
	return mapping
}

// read_property collects the ranges of one property, "0041..005A ; Cased # ...", sorted and with
// neighbors joined.
read_property :: proc(lines: []string, property: string) -> []Range {
	ranges: [dynamic]Range
	for line in lines {
		data, _, _ := strings.partition(strings.trim_right(line, "\r"), "#")
		codes, _, name := strings.partition(data, ";")
		if strings.trim_space(name) != property {
			continue
		}
		first_text, _, last_text := strings.partition(strings.trim_space(codes), "..")
		first := parse_code_point(first_text)
		last := first if last_text == "" else parse_code_point(last_text)
		if last < first {
			fail("DerivedCoreProperties.txt: a reversed range in %q", line)
		}
		append(&ranges, Range{first, last})
	}
	if len(ranges) == 0 {
		fail("DerivedCoreProperties.txt: no %s ranges", property)
	}
	slice.sort_by(ranges[:], proc(a, b: Range) -> bool {return a[0] < b[0]})

	joined: [dynamic]Range
	for r in ranges {
		if len(joined) > 0 && r[0] <= joined[len(joined) - 1][1] + 1 {
			last := &joined[len(joined) - 1][1]
			last^ = max(last^, r[1])
			continue
		}
		append(&joined, r)
	}
	return joined[:]
}

// runs_of folds mappings in code point order into runs: consecutive code points with one delta, or
// every other code point with one delta, the shape of the alternating upper and lower pairs in
// Latin Extended-A and Cyrillic. A code point between two members of a step 2 run has no mapping of
// its own, because the walk would have met it first and closed the run.
runs_of :: proc(mappings: []Mapping) -> []Run {
	runs: [dynamic]Run
	for m in mappings {
		delta := i32(m.to - m.from)
		if len(runs) > 0 {
			run := &runs[len(runs) - 1]
			gap := i32(m.from - run.last)
			if run.delta == delta && run.first == run.last && (gap == 1 || gap == 2) {
				run.step = gap
				run.last = m.from
				continue
			}
			if run.delta == delta && gap == run.step {
				run.last = m.from
				continue
			}
		}
		append(&runs, Run{m.from, m.from, delta, 1})
	}
	return runs[:]
}

write_header :: proc(b: ^strings.Builder, version: string) {
	fmt.sbprintf(
		b,
		`// Generated from the Unicode Character Database %s; do not edit. Regenerate with
//
//	odin run src/runtime/str/tools -- <ucd dir> src/runtime/str/case_tables.odin

package str
`,
		version,
	)
}

write_runs :: proc(b: ^strings.Builder, name: string, runs: []Run) {
	fmt.sbprintf(b, "\n@(private, rodata)\n%s := [?]Case_Run {{\n", name)
	for r in runs {
		first, last := u32(r.first), u32(r.last)
		fmt.sbprintf(b, "\t{{0x%04x, 0x%04x, %d, %d}},\n", first, last, r.delta, r.step)
	}
	strings.write_string(b, "}\n")
}

write_specials :: proc(b: ^strings.Builder, specials: []Special) {
	strings.write_string(b, "\n@(private, rodata)\nSPECIAL := [?]Special_Case {\n")
	for s in specials {
		fmt.sbprintf(b, "\t{{0x%04x, ", u32(s.code))
		write_units(b, s.lower)
		strings.write_string(b, ", ")
		write_units(b, s.upper)
		strings.write_string(b, "},\n")
	}
	strings.write_string(b, "}\n")
}

write_units :: proc(b: ^strings.Builder, mapping: []rune) {
	strings.write_byte(b, '{')
	for i in 0 ..< SPECIAL_MAX {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		fmt.sbprintf(b, "0x%04x", u32(mapping[i]) if i < len(mapping) else 0)
	}
	strings.write_byte(b, '}')
}

write_ranges :: proc(b: ^strings.Builder, name: string, ranges: []Range) {
	fmt.sbprintf(b, "\n@(private, rodata)\n%s := [?][2]rune {{\n", name)
	for r in ranges {
		fmt.sbprintf(b, "\t{{0x%04x, 0x%04x}},\n", u32(r[0]), u32(r[1]))
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

is_surrogate :: proc(r: rune) -> bool {
	return 0xd800 <= r && r <= 0xdfff
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}
