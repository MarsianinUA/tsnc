/*
The expect mode: every program in tests/expect/ must print what its own header says, byte for byte,
and end with the exit code the header names. docs/development.md#expected-output-tests has the
header and what the corpus holds.

Exit code 1 is also SIGHUP's number on POSIX, where a signal and an exit read alike (SIGNAL_MAX in
compare.odin). A crash never prints the line src/runtime/fail writes, so stderr tells the two apart.
*/
package main

import "core:fmt"
import "core:os"
import "core:strings"

import "../../src/link"

// EXPECT_CORPUS is relative to the current directory, as the compiler path in runner.odin is: the
// runner is started from the repository root.
EXPECT_CORPUS :: "tests/expect"

expect_program :: proc(compiler, dist, path: string, sanitizer: link.Sanitizer) -> (ok: bool) {
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
	for line in header_lines(string(data)) {
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
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
	if want.code > 1 && !own_exit_code(want.code) {
		fmt.eprintfln(
			"expect: %s: exit code %d: a program exits with 0, 1 or %d..%d",
			path,
			want.code,
			SIGNAL_MAX + 1,
			EXIT_MAX,
		)
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
