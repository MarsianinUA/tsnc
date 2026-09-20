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

The mode runs the compiler the build left in dist/ instead of calling driver in process, so that
the rendered message, the code number, the choice of stderr and the exit code are covered as well
as the diagnostics themselves. The first corpus is the syntactic "never" rules of requirements 2.2
and the jumps with nowhere to go; T3.6 adds the semantic and type rules.
*/
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

// COMPILER and CORPUS are relative to the current directory, as smoke's dist/ paths already are:
// the runner is started from the repository root.
COMPILER :: "dist/tsnc.exe"
CORPUS :: "tests/negative"

// COMPILER_BUILD builds the compiler this mode runs.
COMPILER_BUILD :: "odin build src -out:dist/tsnc.exe -o:speed -vet -strict-style"

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
	if !os.is_file(COMPILER) {
		fmt.eprintfln("negative: %s is missing", COMPILER)
		fmt.eprintln("run the runner from the repository root, and build the compiler first:")
		fmt.eprintfln("  %s", COMPILER_BUILD)
		return false
	}

	// An absolute path, so that running it does not depend on how the OS resolves a relative one,
	// as smoke already found. The programs keep their relative paths: the compiler inherits this
	// directory, and a short path keeps the diagnostics readable in a CI log.
	compiler, path_err := os.get_absolute_path(COMPILER, context.temp_allocator)
	if path_err != nil {
		fmt.eprintfln("negative: absolute path of %s: %v", COMPILER, path_err)
		return false
	}

	// The listing stays in the temp allocator for the whole run. Everything here is allocated
	// before the first check_program, and that procedure's temp guard releases only what the call
	// itself allocated, so these names stay valid to the end.
	entries, dir_err := os.read_all_directory_by_path(CORPUS, context.temp_allocator)
	if dir_err != nil {
		fmt.eprintfln("negative: read %s: %v", CORPUS, dir_err)
		fmt.eprintln("run the runner from the repository root")
		return false
	}

	// Sorted by name: a file system lists a directory in whatever order it keeps it, and two runs
	// of the corpus should print the same log.
	names := make([dynamic]string, context.temp_allocator)
	for entry in entries {
		if strings.has_suffix(entry.name, ".ts") {
			append(&names, entry.name)
		}
	}
	slice.sort(names[:])
	if len(names) == 0 {
		fmt.eprintfln("negative: no .ts program in %s", CORPUS)
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

	path := fmt.tprintf("%s/%s", CORPUS, name)
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
@(private = "file")
diagnostics_of :: proc(path, text: string) -> (got: []Expected, ok: bool) {
	list := make([dynamic]Expected, context.temp_allocator)
	ok = true

	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if line == "" || strings.has_prefix(line, HINT_PREFIX) {
			continue
		}
		printed, line_ok := parse_diagnostic(line)
		if !line_ok {
			fmt.eprintfln("negative: %s: cannot read the compiler output %q", path, line)
			ok = false
			continue
		}
		append(&list, printed)
	}
	return list[:], ok
}

// parse_diagnostic reads the error line of a rendered diagnostic. Only the code and the position
// are read: the text and the hint belong to the diag registry, which tests/diag already covers.
@(private = "file")
parse_diagnostic :: proc(line: string) -> (printed: Expected, ok: bool) {
	marker := strings.index(line, MARKER)
	if marker < 0 {
		return {}, false
	}

	// Before the marker stands `<path>:<line>:<column>`, read from the right so that the path is
	// left alone whatever it holds.
	head := line[:marker]
	column_colon := strings.last_index_byte(head, ':')
	if column_colon < 0 {
		return {}, false
	}
	line_colon := strings.last_index_byte(head[:column_colon], ':')
	if line_colon < 0 {
		return {}, false
	}
	printed.line = parse_number(head[line_colon + 1:column_colon]) or_return
	printed.column = parse_number(head[column_colon + 1:]) or_return

	// After the marker stands the number, then `]`.
	tail := line[marker + len(MARKER):]
	close := strings.index_byte(tail, ']')
	if close < 0 {
		return {}, false
	}
	printed.number = parse_number(tail[:close]) or_return
	return printed, true
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
