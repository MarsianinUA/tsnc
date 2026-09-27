/*
What the diff and expect modes share: build a corpus program with `tsnc build`, run what came out,
and compare its stdout, stderr and exit code with a reference, byte for byte. The modes differ only
in where the reference comes from: diff runs Node, expect reads the program's own header.

Every program is built twice. A corpus program reads nothing from the outside, so at -o:speed LLVM
folds most of one into constants and the sequences codegen emits for ToInt32, for the shift masks
and for the corners of `**` never execute at all; -o:none is where they do. -o:speed is what a user
gets. Both builds are compared against the same reference.

With -sanitize:address every build links the runtime built with AddressSanitizer. The reference
stays what it was.
*/
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../../src/link"
import "../../src/target"

// Level carries a suffix that keeps the artifacts of one program apart, so a build that failed
// leaves the other one behind to look at.
Level :: struct {
	flag:   string, // as `tsnc build` spells it
	suffix: string, // as the artifact is named
}

@(rodata)
LEVELS := [?]Level{{flag = "-o:none", suffix = "none"}, {flag = "-o:speed", suffix = "speed"}}

Output :: struct {
	stdout: string,
	stderr: string,
	code:   int,
}

// corpus_names sorts the programs: a file system lists a directory in whatever order it keeps it,
// and two runs of the corpus should print the same log.
corpus_names :: proc(mode: Mode, directory: string) -> (names: []string, ok: bool) {
	entries, dir_err := os.read_all_directory_by_path(directory, context.temp_allocator)
	if dir_err != nil {
		fmt.eprintfln("%v: read %s: %v", mode, directory, dir_err)
		fmt.eprintln("run the runner from the repository root")
		return nil, false
	}

	// A directory is skipped: modules/ exists to be imported rather than run.
	list := make([dynamic]string, context.temp_allocator)
	for entry in entries {
		if entry.type != .Directory && strings.has_suffix(entry.name, ".ts") {
			append(&list, entry.name)
		}
	}
	slice.sort(list[:])
	if len(list) == 0 {
		fmt.eprintfln("%v: no .ts program in %s", mode, directory)
		return nil, false
	}
	return list[:], true
}

// dist_directory is where the artifacts go: beside the compiler, under names of their own. An
// absolute path, so that running one does not depend on how the OS resolves a relative one, as
// smoke already found; it is built from dist/, because on Linux and macOS get_absolute_path
// resolves only a path that already exists.
dist_directory :: proc(mode: Mode) -> (dist: string, ok: bool) {
	path, path_err := os.get_absolute_path("dist", context.temp_allocator)
	if path_err != nil {
		fmt.eprintfln("%v: absolute path of dist: %v", mode, path_err)
		return "", false
	}
	return path, true
}

// compare_builds keeps the path relative: the compiler inherits this directory, a short path keeps
// the report readable in a CI log, and a failure message names the program by it on every OS. A
// nil environment is the runner's own.
compare_builds :: proc(
	mode: Mode,
	compiler, dist, path: string,
	sanitizer: link.Sanitizer,
	want: Output,
	arguments: []string = nil,
	environment: []string = nil,
) -> (
	ok: bool,
) {
	stem := strings.trim_suffix(os.base(path), ".ts")
	suffix := target.SPECS[target.HOST].executable_suffix

	ok = true
	for level in LEVELS {
		artifact := fmt.tprintf("%v-%s-%s%s", mode, stem, level.suffix, suffix)
		program, join_err := os.join_path({dist, artifact}, context.temp_allocator)
		if join_err != nil {
			fmt.eprintfln("%v: %s: path of %s: %v", mode, path, artifact, join_err)
			ok = false
			continue
		}

		command := make([dynamic]string, context.temp_allocator)
		append(&command, compiler, "build", path, level.flag, fmt.tprintf("-out:%s", program))
		if sanitizer != .none {
			append(&command, fmt.tprintf("-sanitize:%v", sanitizer))
		}
		run := slice.concatenate([][]string{{program}, arguments}, context.temp_allocator)
		if !compare_level(mode, path, level, command[:], run, environment, want) {
			ok = false
		}
	}
	return ok
}

@(private = "file")
compare_level :: proc(
	mode: Mode,
	path: string,
	level: Level,
	build, run, environment: []string,
	want: Output,
) -> (
	ok: bool,
) {
	built := execute(mode, path, "tsnc build", build) or_return
	if built.code != 0 || built.stdout != "" || built.stderr != "" {
		// A corpus program compiles. Whatever the compiler said about this one is the whole answer,
		// so it goes through as it was written and nothing is run.
		fmt.eprintfln("%v: %s: %s: the build answered %d", mode, path, level.flag, built.code)
		fmt.eprint(built.stdout)
		fmt.eprint(built.stderr)
		return false
	}

	got := execute(mode, path, run[0], run, environment) or_return
	ok = true
	if !same_stream(mode, path, level, "stdout", got.stdout, want.stdout) {
		ok = false
	}
	if !same_stream(mode, path, level, "stderr", got.stderr, want.stderr) {
		ok = false
	}
	if got.code != want.code {
		fmt.eprintfln(
			"%v: %s: %s: exit code or signal: got %d, want %d",
			mode,
			path,
			level.flag,
			got.code,
			want.code,
		)
		ok = false
	}
	return ok
}

// execute reports a program that could not be started at all, and the caller stops: there is
// nothing left to compare. A nil environment is the runner's own.
execute :: proc(
	mode: Mode,
	path, what: string,
	command: []string,
	environment: []string = nil,
) -> (
	output: Output,
	ok: bool,
) {
	description := os.Process_Desc {
		command = command,
		env     = environment,
	}
	state, stdout, stderr, err := os.process_exec(description, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("%v: %s: run %s: %v", mode, path, what, err)
		return {}, false
	}
	return Output{stdout = string(stdout), stderr = string(stderr), code = state.exit_code}, true
}

// same_stream names only the first line where the two streams part: a corpus program prints a
// couple of dozen lines, and dumping both streams into a CI log buries the one that moved.
@(private = "file")
same_stream :: proc(mode: Mode, path: string, level: Level, stream, got, want: string) -> bool {
	if got == want {
		return true
	}

	got_lines := strings.split_lines(got, context.temp_allocator)
	want_lines := strings.split_lines(want, context.temp_allocator)
	for index in 0 ..< max(len(got_lines), len(want_lines)) {
		if index < len(got_lines) &&
		   index < len(want_lines) &&
		   got_lines[index] == want_lines[index] {
			continue
		}
		fmt.eprintfln(
			"%v: %s: %s: %s line %d: got %s, want %s",
			mode,
			path,
			level.flag,
			stream,
			index + 1,
			describe_line(got_lines, index),
			describe_line(want_lines, index),
		)
		return false
	}

	// Every line matched although the streams did not, which only a line ending can do:
	// split_lines makes nothing of the difference between "a\n" and "a\r\n".
	fmt.eprintfln("%v: %s: %s: %s: got %q, want %q", mode, path, level.flag, stream, got, want)
	return false
}

@(private = "file")
describe_line :: proc(lines: []string, index: int) -> string {
	if index >= len(lines) {
		return "nothing"
	}
	return fmt.tprintf("%q", lines[index])
}

// parse_number reads a whole string of digits. strconv stops at the first byte it does not
// understand, and a test must never read `5x` as 5.
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
