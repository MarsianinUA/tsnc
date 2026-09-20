/*
The negative mode: every program in tests/negative/ must fail to compile in exactly the way its own
header says it does.

A corpus program opens with a header: the run of blank and comment lines at the top, ending at the
first line that is neither. A header line of the form

	// expect: T2001 5:1

names one diagnostic, spelled the way `tsnc check` prints it: the code, then the 1-based line and
column of its position, where a column counts UTF-16 code units (src/source). Every other header
line is prose about the rule the program pins.

The expectations are the whole truth about a program. They are compared with what the compiler
printed one for one and in order, so a diagnostic the header does not mention fails the program
exactly as a missing one does; otherwise parser recovery could start emitting noise and no test
would notice. For the same reason a program with no expectation at all fails, and so does a
malformed `// expect:` line: skipping either would leave a test that proves nothing.

An expectation has no file in it, because every diagnostic it can name stands in the program
itself. A program may still import: the modules under tests/negative/modules/ are there to be
imported and are never run as programs of their own, since the walk over the corpus takes only the
`.ts` files directly in tests/negative. A diagnostic printed for any other file fails the program
rather than sliding into the comparison unseen, which is what keeps a rule about two modules
honest: the message has to land where the header says it does.

The mode runs the compiler the build left in dist/ instead of calling driver in process, so that
the rendered message, the code number, the choice of stderr and the exit code are covered as well
as the diagnostics themselves. The corpus holds one program for every rule of the subset and every
rule of the types, which is one program per code of the diag registry, except the lexer and parser
codes that tests/parse owns and the fifty constructs that share T2021, grouped three ways.
*/
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// NEGATIVE_CORPUS is relative to the current directory, as the compiler path in runner.odin is:
// the runner is started from the repository root.
NEGATIVE_CORPUS :: "tests/negative"

// EXPECT_PREFIX opens a header line that names one diagnostic; EXPECT_EXAMPLE shows the whole form
// in the message about a line that does not parse.
EXPECT_PREFIX :: "// expect:"
EXPECT_EXAMPLE :: "// expect: T2001 5:1"

// MARKER stands between the position of a rendered diagnostic and its code:
//
//	tests/negative/var.ts:5:1: error[T2001]: `var` is not supported
//
// The parse finds it and then reads the position from the right, rather than counting colons from
// the left, so that a path holding a colon of its own cannot throw it off.
MARKER :: ": error[T"

// HINT_PREFIX opens the second line of every rendered diagnostic.
HINT_PREFIX :: "  hint: "

// Expected is one diagnostic, either as a header expects it or as the compiler printed it. It has
// no file: every program in the corpus is a single file, so every diagnostic comes from that file.
Expected :: struct {
	number: int, // the code as diag prints it, without the leading T
	line:   int,
	column: int,
}

// negative runs every program in the corpus. It reports every mismatch instead of stopping at the
// first, so that one CI log shows all of them.
negative :: proc() -> (passed: bool) {
	// The programs keep their relative paths: the compiler inherits this directory, and a short
	// path keeps the diagnostics readable in a CI log.
	compiler := compiler_path("negative") or_return

	// The listing stays in the temp allocator for the whole run. Everything here is allocated
	// before the first check_program, and that procedure's temp guard releases only what the call
	// itself allocated, so these names stay valid to the end.
	entries, dir_err := os.read_all_directory_by_path(NEGATIVE_CORPUS, context.temp_allocator)
	if dir_err != nil {
		fmt.eprintfln("negative: read %s: %v", NEGATIVE_CORPUS, dir_err)
		fmt.eprintln("run the runner from the repository root")
		return false
	}

	// A directory is skipped even when it is named like a source file: tests/negative/modules/
	// holds one on purpose, to give an import something it cannot read.
	names := make([dynamic]string, context.temp_allocator)
	for entry in entries {
		if entry.type != .Directory && strings.has_suffix(entry.name, ".ts") {
			append(&names, entry.name)
		}
	}
	// Sorted by name: a file system lists a directory in whatever order it keeps it, and two runs
	// of the corpus should print the same log.
	slice.sort(names[:])
	if len(names) == 0 {
		fmt.eprintfln("negative: no .ts program in %s", NEGATIVE_CORPUS)
		return false
	}

	passed = true
	diagnostics := 0
	for name in names {
		printed, ok := check_program(compiler, name)
		diagnostics += printed
		if !ok {
			passed = false
		}
	}
	if passed {
		fmt.printfln("negative: ok (%d programs, %d diagnostics)", len(names), diagnostics)
	}
	return passed
}

// check_program runs one corpus program and compares what the compiler printed with what the
// program's header expects. It answers how many diagnostics the compiler printed, for the summary.
@(private = "file")
check_program :: proc(compiler, name: string) -> (printed: int, ok: bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	path := fmt.tprintf("%s/%s", NEGATIVE_CORPUS, name)
	text, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("negative: %s: read: %v", path, read_err)
		return 0, false
	}
	want, want_ok := expectations(path, string(text))

	state, stdout, stderr, run_err := os.process_exec(
		{command = {compiler, "check", path}},
		context.temp_allocator,
	)
	if run_err != nil {
		fmt.eprintfln("negative: %s: run %s: %v", path, compiler, run_err)
		return 0, false
	}
	got, got_ok := diagnostics_of(path, string(stderr))

	ok = want_ok && got_ok
	if state.exit_code != 1 {
		// `tsnc check` answers 1 for a program with any diagnostic and 0 for a clean one, so a
		// negative test always expects 1. A crash lands here too, with whatever the OS reports.
		fmt.eprintfln("negative: %s: exit code: got %d, want 1", path, state.exit_code)
		ok = false
	}
	if len(stdout) > 0 {
		// check writes to stderr alone, so that the diagnostics of a build never mix with the
		// output of a program under `tsnc run`.
		fmt.eprintfln("negative: %s: stdout: got %q, want nothing", path, string(stdout))
		ok = false
	}

	// Compared by position, so that a missing, an extra and a wrong diagnostic all read alike. A
	// header that did not parse has already been reported and is not worth comparing against.
	if want_ok {
		for index in 0 ..< max(len(want), len(got)) {
			if index < len(want) && index < len(got) && want[index] == got[index] {
				continue
			}
			fmt.eprintfln(
				"negative: %s: diagnostic %d: got %s, want %s",
				path,
				index + 1,
				describe(got, index),
				describe(want, index),
			)
			ok = false
		}
	}
	return len(got), ok
}

// expectations reads the `// expect:` lines of the header of text. The header ends at the first
// line that is neither blank nor a comment, so an expectation always sits above the program it
// describes.
@(private = "file")
expectations :: proc(path, text: string) -> (want: []Expected, ok: bool) {
	list := make([dynamic]Expected, context.temp_allocator)
	ok = true

	rest := text
	number := 0
	for line in strings.split_lines_iterator(&rest) {
		number += 1
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		if !strings.has_prefix(trimmed, "//") {
			break
		}
		if !strings.has_prefix(trimmed, EXPECT_PREFIX) {
			continue
		}
		expected, line_ok := parse_expectation(strings.trim_space(trimmed[len(EXPECT_PREFIX):]))
		if !line_ok {
			fmt.eprintfln("negative: %s:%d: cannot read %q", path, number, trimmed)
			fmt.eprintfln("  an expectation reads: %s", EXPECT_EXAMPLE)
			ok = false
			continue
		}
		append(&list, expected)
	}

	if ok && len(list) == 0 {
		fmt.eprintfln("negative: %s: the header expects nothing", path)
		fmt.eprintfln("  a negative test names every diagnostic it expects: %s", EXPECT_EXAMPLE)
		ok = false
	}
	return list[:], ok
}

// parse_expectation reads the body of an expectation, `T2001 5:1`.
@(private = "file")
parse_expectation :: proc(body: string) -> (expected: Expected, ok: bool) {
	fields := strings.fields(body, context.temp_allocator)
	if len(fields) != 2 || !strings.has_prefix(fields[0], "T") {
		return {}, false
	}

	// The range is the one diag guarantees, so that a typo such as T20 cannot pass for a code.
	expected.number = parse_number(fields[0][1:]) or_return
	if expected.number < 1000 || expected.number > 9999 {
		return {}, false
	}

	colon := strings.index_byte(fields[1], ':')
	if colon < 0 {
		return {}, false
	}
	expected.line = parse_number(fields[1][:colon]) or_return
	expected.column = parse_number(fields[1][colon + 1:]) or_return
	if expected.line < 1 || expected.column < 1 {
		return {}, false
	}
	return expected, true
}

// diagnostics_of reads what `tsnc check` printed. Every diagnostic is two lines, the error and its
// hint. A line that is neither is the compiler saying something an expectation cannot express,
// such as an entry file it could not read, and it fails the program rather than passing unseen.
//
// A diagnostic about another file fails the program as well. A corpus program may import a module
// from tests/negative/modules/, and an expectation names no file, so a message from there would
// otherwise be compared as if it stood in the program itself. The paths compare as written: the
// compiler prints a file under the spelling it was reached by, folded with forward slashes, and
// the entry file is reached under exactly the path this runner passed on the command line.
@(private = "file")
diagnostics_of :: proc(path, text: string) -> (got: []Expected, ok: bool) {
	list := make([dynamic]Expected, context.temp_allocator)
	ok = true

	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if line == "" || strings.has_prefix(line, HINT_PREFIX) {
			continue
		}
		printed, file, line_ok := parse_diagnostic(line)
		if !line_ok {
			fmt.eprintfln("negative: %s: cannot read the compiler output %q", path, line)
			ok = false
			continue
		}
		if file != path {
			fmt.eprintfln("negative: %s: diagnostic in %s: %s", path, file, line)
			fmt.eprintln("  a program expects only what stands in the program itself")
			ok = false
			continue
		}
		append(&list, printed)
	}
	return list[:], ok
}

// parse_diagnostic reads the error line of a rendered diagnostic: the file it stands in, its
// position and its code. The text and the hint belong to the diag registry, which tests/diag
// already covers.
@(private = "file")
parse_diagnostic :: proc(line: string) -> (printed: Expected, file: string, ok: bool) {
	marker := strings.index(line, MARKER)
	if marker < 0 {
		return {}, "", false
	}

	// Before the marker stands `<path>:<line>:<column>`, read from the right so that the path is
	// left alone whatever it holds.
	head := line[:marker]
	column_colon := strings.last_index_byte(head, ':')
	if column_colon < 0 {
		return {}, "", false
	}
	line_colon := strings.last_index_byte(head[:column_colon], ':')
	if line_colon < 0 {
		return {}, "", false
	}
	file = head[:line_colon]
	printed.line = parse_number(head[line_colon + 1:column_colon]) or_return
	printed.column = parse_number(head[column_colon + 1:]) or_return

	// After the marker stands the number, then `]`.
	tail := line[marker + len(MARKER):]
	close := strings.index_byte(tail, ']')
	if close < 0 {
		return {}, "", false
	}
	printed.number = parse_number(tail[:close]) or_return
	return printed, file, true
}

// parse_number reads a whole string of digits. strconv stops at the first byte it does not
// understand, and a test must never read `5x` as 5.
@(private = "file")
parse_number :: proc(text: string) -> (value: int, ok: bool) {
	if text == "" {
		return 0, false
	}
	for index in 0 ..< len(text) {
		if text[index] < '0' || text[index] > '9' {
			return 0, false
		}
	}
	return strconv.parse_int(text, 10)
}

// describe names one diagnostic of a list for a mismatch line, or says that the list ended there.
@(private = "file")
describe :: proc(list: []Expected, index: int) -> string {
	if index >= len(list) {
		return "nothing"
	}
	return fmt.tprintf("T%d %d:%d", list[index].number, list[index].line, list[index].column)
}
