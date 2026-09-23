/*
The diff mode: every program in tests/diff/ must print what Node prints, byte for byte.

A corpus program is a whole program, not a fragment, and it carries no expected output of its own.
The expectation is Node: the mode runs `node <program>`, then builds the same file with `tsnc build`
and runs what came out, and compares stdout, stderr and the exit code. Nothing is normalized on the
way, neither line endings nor encoding, because a difference in either is exactly the kind of thing
this test exists to find.

Before any of that the corpus passes a gate: `tsc --noEmit --strict` over tests/diff/tsconfig.json,
so that a corpus program is TypeScript the real compiler accepts and not merely something tsnc
happens to swallow (requirements 10). The gate runs once for the whole corpus and is a precondition
rather than a test of its own: a program that does not type-check is a broken corpus, and tsc names
every file and line it objects to, so one run still shows all of them.

tests/diff is an npm project, laid out the way one is: package.json, package-lock.json and
tsconfig.json at the top, the node_modules npm unpacks from them beside those, and the programs
under src/. The manifests sit above the programs rather than elsewhere in tests/, because Node reads
`"type": "module"` from the nearest package.json and it has to be an ancestor of the programs for an
import in one of them to run at all.

Every program is built twice. A corpus program reads nothing from the outside, so at -o:speed LLVM
folds most of one into constants and the sequences codegen emits for ToInt32, for the shift masks
and for the corners of `**` never execute at all; -o:none is where they do. -o:speed is what a user
gets. Both builds are compared against the same Node output.

The walk takes only the `.ts` files directly in tests/diff/src, the way the negative corpus does:
the modules under tests/diff/src/modules/ are there to be imported and are never run as programs of
their own.

A program whose first line is `// env: NAME=value ...` runs, under Node and as the build, in the
runner's environment with those variables set, an empty value included. colors.ts sets FORCE_COLOR
that way, which is the one way to see colors through a pipe.
*/
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import "../../src/target"

// DIFF_PROJECT and DIFF_CORPUS are relative to the current directory, as the compiler path in
// runner.odin is: the runner is started from the repository root.
DIFF_PROJECT :: "tests/diff"
DIFF_CORPUS :: DIFF_PROJECT + "/src"

// TSC is the launcher npm installs from the project's package.json: a JavaScript file that loads
// the compiler, so one command starts it on every system, and TSC_INSTALL puts it there.
TSC :: DIFF_PROJECT + "/node_modules/typescript/bin/tsc"
TSC_INSTALL :: "npm ci --prefix " + DIFF_PROJECT

// NODE is named without a path, so the OS finds it the way it finds any program. Requirements 10
// pin Node 24, which runs a .ts file with no flags and is what makes it a reference at all.
NODE :: "node"

// Level carries a suffix that keeps the artifacts of one program apart, so a build that failed
// leaves the other one behind to look at.
Level :: struct {
	flag:   string, // as `tsnc build` spells it
	suffix: string, // as the artifact is named
}

@(rodata)
LEVELS := [?]Level{{flag = "-o:none", suffix = "none"}, {flag = "-o:speed", suffix = "speed"}}

// A death by signal and an exit read the same on POSIX: os.Process_State puts the signal's number
// where the code goes and clears success for both, and on Windows a crash is an NTSTATUS for a
// code. So the code is all there is to compare, and a corpus program keeps its own code above
// every signal number, where a crash can never pass for the right answer.
SIGNAL_MAX :: 64

Output :: struct {
	stdout: string,
	stderr: string,
	code:   int,
}

// diff reports every mismatch instead of stopping at the first, so that one CI log shows all of
// them.
diff :: proc() -> (passed: bool) {
	compiler := compiler_path("diff") or_return

	// The programs keep their relative paths: the compiler inherits this directory, and a short
	// path keeps the report readable in a CI log.
	names := corpus_names() or_return
	gate() or_return

	// The artifacts go beside the compiler, under names of their own. An absolute path, so that
	// running one does not depend on how the OS resolves a relative one, as smoke already found; it
	// is built from dist/, because on Linux and macOS get_absolute_path resolves only a path that
	// already exists.
	dist, path_err := os.get_absolute_path("dist", context.temp_allocator)
	if path_err != nil {
		fmt.eprintfln("diff: absolute path of dist: %v", path_err)
		return false
	}

	passed = true
	for name in names {
		if !compare_program(compiler, dist, name) {
			passed = false
		}
	}
	if passed {
		fmt.printfln("diff: ok (%d programs, %d builds)", len(names), len(names) * len(LEVELS))
	}
	return passed
}

// corpus_names sorts the programs: a file system lists a directory in whatever order it keeps it,
// and two runs of the corpus should print the same log.
@(private = "file")
corpus_names :: proc() -> (names: []string, ok: bool) {
	entries, dir_err := os.read_all_directory_by_path(DIFF_CORPUS, context.temp_allocator)
	if dir_err != nil {
		fmt.eprintfln("diff: read %s: %v", DIFF_CORPUS, dir_err)
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
		fmt.eprintfln("diff: no .ts program in %s", DIFF_CORPUS)
		return nil, false
	}
	return list[:], true
}

@(private = "file")
gate :: proc() -> (ok: bool) {
	if !os.is_file(TSC) {
		fmt.eprintfln("diff: %s is missing", TSC)
		fmt.eprintfln(
			"the gate needs TypeScript, installed once from %s/package.json:",
			DIFF_PROJECT,
		)
		fmt.eprintfln("  %s", TSC_INSTALL)
		return false
	}

	state, stdout, stderr, err := os.process_exec(
		{command = {NODE, TSC, "--noEmit", "--strict", "-p", DIFF_PROJECT}},
		context.temp_allocator,
	)
	if err != nil {
		fmt.eprintfln("diff: gate: run %s: %v", NODE, err)
		fmt.eprintln("the corpus needs Node 24: it runs the reference and hosts the gate")
		return false
	}
	if state.exit_code == 0 {
		return true
	}

	fmt.eprintfln("diff: the gate rejected the corpus: tsc --noEmit --strict -p %s", DIFF_PROJECT)
	// tsc writes its diagnostics to stdout; stderr carries whatever stopped it from starting.
	fmt.eprint(string(stdout))
	fmt.eprint(string(stderr))
	return false
}

@(private = "file")
compare_program :: proc(compiler, dist, name: string) -> (ok: bool) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	path := fmt.tprintf("%s/%s", DIFF_CORPUS, name)
	environment := program_environment(path) or_return
	want := execute(path, "node", {NODE, path}, environment) or_return
	if want.code >= 1 && want.code <= SIGNAL_MAX {
		fmt.eprintfln(
			"diff: %s: exit code %d is also a signal's number; a corpus program exits with 0 or %d..125",
			path,
			want.code,
			SIGNAL_MAX + 1,
		)
		return false
	}

	stem := strings.trim_suffix(name, ".ts")
	suffix := target.SPECS[target.HOST].executable_suffix

	ok = true
	for level in LEVELS {
		artifact := fmt.tprintf("diff-%s-%s%s", stem, level.suffix, suffix)
		program, join_err := os.join_path({dist, artifact}, context.temp_allocator)
		if join_err != nil {
			fmt.eprintfln("diff: %s: path of %s: %v", path, artifact, join_err)
			ok = false
			continue
		}
		if !compare_level(compiler, path, program, level, want, environment) {
			ok = false
		}
	}
	return ok
}

@(private = "file")
compare_level :: proc(
	compiler, path, program: string,
	level: Level,
	want: Output,
	environment: []string,
) -> (
	ok: bool,
) {
	command := [?]string{compiler, "build", path, level.flag, fmt.tprintf("-out:%s", program)}
	built := execute(path, "tsnc build", command[:]) or_return
	if built.code != 0 || built.stdout != "" || built.stderr != "" {
		// A corpus program compiles. Whatever the compiler said about this one is the whole answer,
		// so it goes through as it was written and nothing is run.
		fmt.eprintfln("diff: %s: %s: the build answered %d", path, level.flag, built.code)
		fmt.eprint(built.stdout)
		fmt.eprint(built.stderr)
		return false
	}

	got := execute(path, program, {program}, environment) or_return
	ok = true
	if !same_stream(path, level, "stdout", got.stdout, want.stdout) {
		ok = false
	}
	if !same_stream(path, level, "stderr", got.stderr, want.stderr) {
		ok = false
	}
	if got.code != want.code {
		fmt.eprintfln(
			"diff: %s: %s: exit code or signal: got %d, want %d",
			path,
			level.flag,
			got.code,
			want.code,
		)
		ok = false
	}
	return ok
}

// program_environment answers nil for a program with no `// env:` line, which keeps the runner's
// environment. A name the line sets replaces the runner's own, whose case Windows ignores.
@(private = "file")
program_environment :: proc(path: string) -> (environment: []string, ok: bool) {
	HEADER :: "// env: "
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("diff: read %s: %v", path, read_err)
		return nil, false
	}
	first, _, _ := strings.partition(string(data), "\n")
	first = strings.trim_right(first, "\r")
	if !strings.has_prefix(first, HEADER) {
		return nil, true
	}
	settings := strings.fields(first[len(HEADER):], context.temp_allocator)
	inherited, env_err := os.environ(context.temp_allocator)
	if env_err != nil {
		fmt.eprintfln("diff: %s: read the environment: %v", path, env_err)
		return nil, false
	}
	list := make([dynamic]string, context.temp_allocator)
	for entry in inherited {
		name, _, _ := strings.partition(entry, "=")
		if !sets(settings, name) {
			append(&list, entry)
		}
	}
	append(&list, ..settings)
	return list[:], true
}

@(private = "file")
sets :: proc(settings: []string, name: string) -> bool {
	for setting in settings {
		set, _, _ := strings.partition(setting, "=")
		same := strings.equal_fold(set, name) if ODIN_OS == .Windows else set == name
		if same {
			return true
		}
	}
	return false
}

// execute reports a program that could not be started at all, and the caller stops: there is
// nothing left to compare. A nil environment is the runner's own.
@(private = "file")
execute :: proc(
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
		fmt.eprintfln("diff: %s: run %s: %v", path, what, err)
		return {}, false
	}
	return Output{stdout = string(stdout), stderr = string(stderr), code = state.exit_code}, true
}

// same_stream names only the first line where the two streams part: a corpus program prints a
// couple of dozen lines, and dumping both streams into a CI log buries the one that moved.
@(private = "file")
same_stream :: proc(path: string, level: Level, stream, got, want: string) -> bool {
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
			"diff: %s: %s: %s line %d: got %s, want %s",
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
	fmt.eprintfln("diff: %s: %s: %s: got %q, want %q", path, level.flag, stream, got, want)
	return false
}

@(private = "file")
describe_line :: proc(lines: []string, index: int) -> string {
	if index >= len(lines) {
		return "nothing"
	}
	return fmt.tprintf("%q", lines[index])
}
