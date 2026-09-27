/*
The expect mode: every program in tests/expect/ must print what its own header says, byte for byte,
and end with the exit code the header names.

The corpus holds what requirements 3.8 keeps out of the diff corpus. Where tsc trusts the
programmer, a compiled program checks, and a failed check writes one line to stderr and exits with
1; Node answers undefined or throws instead, so it cannot be the reference. The reference is
written down in the header:

	// stdout: 4
	// stderr: error: non-null assertion failed at tests/expect/non-null.ts:8:41
	// exit: 1

The header is the run of blank and comment lines at the top, as in the negative corpus, and a
comment of another form is prose. Each `// stdout:` or `// stderr:` line is one line of its
stream, in order, and a bare `// stdout:` is an empty line; a stream the header gives no line
must stay empty. There is exactly one `// exit:`. A line that names stdout:, stderr: or exit:
spelled another way is refused rather than read as prose, since the program could pass without it.

A program is built by its relative path, so its failure message reads the same on every OS. The
two builds, the stress mode TSNC_GC_STRESS passes on to them and -sanitize:address are the diff
mode's (compare.odin), and so is the gate: tests/diff/tsconfig.json includes the programs here and
nothing beside them, so a program imports nothing.

Exit code 1 is also SIGHUP's number on POSIX, where a signal and an exit read alike (SIGNAL_MAX in
diff.odin). A crash never prints the line src/runtime/fail writes, so stderr tells the two apart.
*/
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

import "../../src/link"

// EXPECT_CORPUS is relative to the current directory, as the compiler path in runner.odin is: the
// runner is started from the repository root.
EXPECT_CORPUS :: "tests/expect"

// expect reports every mismatch instead of stopping at the first, so that one CI log shows all of
// them.
expect :: proc(sanitizer: link.Sanitizer) -> (passed: bool) {
	compiler := compiler_path("expect") or_return
	names := corpus_names(.expect, EXPECT_CORPUS) or_return
	gate(.expect) or_return
	dist := dist_directory(.expect) or_return

	passed = true
	for name in names {
		if !expect_program(compiler, dist, name, sanitizer) {
			passed = false
		}
	}
	if passed {
		fmt.printfln("expect: ok (%d programs, %d builds)", len(names), len(names) * len(LEVELS))
	}
	return passed
}

@(private = "file")
expect_program :: proc(compiler, dist, name: string, sanitizer: link.Sanitizer) -> (ok: bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	path := fmt.tprintf("%s/%s", EXPECT_CORPUS, name)
	want := read_expectation(path) or_return
	return compare_builds(.expect, compiler, dist, path, sanitizer, want)
}

@(private = "file")
read_expectation :: proc(path: string) -> (want: Output, ok: bool) {
	STDOUT :: "// stdout:"
	STDERR :: "// stderr:"
	EXIT :: "// exit: "
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("expect: read %s: %v", path, read_err)
		return {}, false
	}

	stdout := strings.builder_make(context.temp_allocator)
	stderr := strings.builder_make(context.temp_allocator)
	has_exit := false
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		if !strings.has_prefix(trimmed, "//") {
			break
		}

		// A key is recognized however it is spaced, so that a misspelled one is refused.
		key := strings.trim_left_space(trimmed[2:])
		value: string
		well_formed := true
		switch {
		case strings.has_prefix(key, "stdout:"):
			value, well_formed = stream_line(line, STDOUT)
			fmt.sbprintln(&stdout, value)
		case strings.has_prefix(key, "stderr:"):
			value, well_formed = stream_line(line, STDERR)
			fmt.sbprintln(&stderr, value)
		case strings.has_prefix(key, "exit:") && !has_exit:
			want.code, well_formed = parse_number(strings.trim_prefix(line, EXIT))
			has_exit = true
		case strings.has_prefix(key, "exit:"):
			fmt.eprintfln("expect: %s: a second header line %q", path, line)
			return {}, false
		}
		if !well_formed {
			fmt.eprintfln("expect: %s: a header line %q is misspelled", path, line)
			fmt.eprintfln("  the header reads: %s text, %s text, %s1", STDOUT, STDERR, EXIT)
			return {}, false
		}
	}
	if !has_exit {
		fmt.eprintfln("expect: %s: the header names no exit code: %s1", path, EXIT)
		return {}, false
	}
	want.stdout = strings.to_string(stdout)
	want.stderr = strings.to_string(stderr)
	return want, true
}

// stream_line reads the text of `// stdout: text`, where a bare `// stdout:` is an empty line.
@(private = "file")
stream_line :: proc(line, prefix: string) -> (text: string, ok: bool) {
	rest := strings.trim_prefix(line, prefix)
	switch {
	case len(rest) == len(line):
		return "", false
	case rest == "":
		return "", true
	case rest[0] != ' ':
		return "", false
	}
	return rest[1:], true
}
