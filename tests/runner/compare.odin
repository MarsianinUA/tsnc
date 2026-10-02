/*
What the diff and expect modes share: build a corpus program with `tsnc build`, run what came out,
and compare its stdout, stderr and exit code with a reference, byte for byte. The modes differ only
in where the reference comes from: diff runs Node, expect reads the program's own header. See
docs/development.md#differential-tests and docs/development.md#expected-output-tests.

Every program is built twice. A corpus program reads nothing from the outside, so at -o:speed LLVM
folds most of one into constants and the sequences codegen emits for ToInt32, for the shift masks
and for the corners of `**` never execute at all; -o:none is where they do. -o:speed is what a user
gets. Both builds are compared against the same reference.

Every build runs twice, as it is and under GC stress, which needs no rebuild. An ASan build runs
under stress alone, for the reason under docs/development.md#addresssanitizer.
*/
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

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

// TIME_LIMIT bounds every process execute starts. The slowest, format.ts at -o:none against the
// ASan runtime under GC stress, took 5.5 s on an i5-13600KF, and a CI runner is slower.
TIME_LIMIT :: 60 * time.Second

// A death by signal and an exit read the same on POSIX: os.Process_State puts the signal's number
// where the code goes and clears success for both, and on Windows a crash is an NTSTATUS for a
// code. So the code is all there is to compare, and a corpus program keeps its own code above
// every signal number, where a crash can never pass for the right answer. Above EXIT_MAX a shell
// reports a command it could not run (126, 127) or a signal (128 plus its number).
SIGNAL_MAX :: 64
EXIT_MAX :: 125

own_exit_code :: proc(code: int) -> bool {
	return SIGNAL_MAX < code && code <= EXIT_MAX
}

STRESS :: "TSNC_GC_STRESS=1"

// run_corpus reports every mismatch instead of stopping at the first, so that one CI log shows all
// of them.
run_corpus :: proc(
	mode: Mode,
	corpus: string,
	sanitizer: link.Sanitizer,
	jobs: int,
	program: Program,
) -> (
	passed: bool,
) {
	compiler := compiler_path(mode) or_return
	paths := corpus_paths(mode, corpus) or_return
	dist := dist_directory(mode) or_return

	report := strings.builder_make(context.temp_allocator)
	template := Job {
		mode      = mode,
		compiler  = compiler,
		dist      = dist,
		sanitizer = sanitizer,
		report    = &report,
	}
	gated := gate(template)
	fmt.eprint(strings.to_string(report))
	if !gated {
		return false
	}

	_, passed = run_programs(template, paths, jobs, program)
	if passed {
		builds := len(paths) * len(LEVELS)
		runs := builds if sanitizer != .none else 2 * builds
		fmt.printfln("%v: ok (%d programs, %d builds, %d runs)", mode, len(paths), builds, runs)
	}
	return passed
}

// corpus_paths sorts the programs: a file system lists a directory in whatever order it keeps it,
// and two runs of the corpus should print the same log.
corpus_paths :: proc(mode: Mode, directory: string) -> (paths: []string, ok: bool) {
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
			append(&list, fmt.tprintf("%s/%s", directory, entry.name))
		}
	}
	slice.sort(list[:])
	if len(list) == 0 {
		fmt.eprintfln("%v: no .ts program in %s", mode, directory)
		return nil, false
	}
	return list[:], true
}

// header_lines answers the run of blank and comment lines at the top of a program; line i of it is
// line i + 1 of the file.
header_lines :: proc(text: string) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		if trimmed != "" && !strings.has_prefix(trimmed, "//") {
			break
		}
		append(&lines, line)
	}
	return lines[:]
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
// the report readable in a CI log, and a failure message names the program by it on every OS.
compare_builds :: proc(
	job: Job,
	path: string,
	want: Output,
	arguments: []string,
	environments: Environments,
) -> (
	ok: bool,
) {
	stem := strings.trim_suffix(os.base(path), ".ts")
	suffix := target.SPECS[target.HOST].executable_suffix

	ok = true
	for level in LEVELS {
		artifact := fmt.tprintf("%v-%s-%s%s", job.mode, stem, level.suffix, suffix)
		program, join_err := os.join_path({job.dist, artifact}, context.temp_allocator)
		if join_err != nil {
			fmt.sbprintfln(
				job.report,
				"%v: %s: path of %s: %v",
				job.mode,
				path,
				artifact,
				join_err,
			)
			ok = false
			continue
		}
		// A build that answers 0 and writes nothing must not run what an earlier run left.
		if remove_err := os.remove(program); remove_err != nil && remove_err != .Not_Exist {
			fmt.sbprintfln(
				job.report,
				"%v: %s: remove %s: %v",
				job.mode,
				path,
				program,
				remove_err,
			)
			ok = false
			continue
		}

		command := make([dynamic]string, context.temp_allocator)
		append(&command, job.compiler, "build", path, level.flag, fmt.tprintf("-out:%s", program))
		if job.sanitizer != .none {
			append(&command, fmt.tprintf("-sanitize:%v", job.sanitizer))
		}
		run := slice.concatenate([][]string{{program}, arguments}, context.temp_allocator)
		if !compare_level(job, path, level, command[:], run, environments, want) {
			ok = false
		}
	}
	return ok
}

// Environments are the two a program runs in. plain is nil when the program sets nothing, which
// keeps the runner's own.
Environments :: struct {
	plain:  []string,
	stress: []string,
}

// environments_for takes the settings of a program's header, nil when it has none.
environments_for :: proc(
	job: Job,
	path: string,
	settings: []string,
) -> (
	environments: Environments,
	ok: bool,
) {
	if settings != nil {
		environments.plain = environment_with(job, path, settings) or_return
	}
	stress := slice.concatenate([][]string{settings, {STRESS}}, context.temp_allocator)
	environments.stress = environment_with(job, path, stress) or_return
	return environments, true
}

// environment_with lets a name the program sets replace the runner's own, whose case Windows
// ignores.
@(private = "file")
environment_with :: proc(
	job: Job,
	path: string,
	settings: []string,
) -> (
	environment: []string,
	ok: bool,
) {
	inherited, env_err := os.environ(context.temp_allocator)
	if env_err != nil {
		fmt.sbprintfln(job.report, "%v: %s: read the environment: %v", job.mode, path, env_err)
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

@(private = "file")
compare_level :: proc(
	job: Job,
	path: string,
	level: Level,
	build, run: []string,
	environments: Environments,
	want: Output,
) -> (
	ok: bool,
) {
	built := execute(job, path, "tsnc build", build) or_return
	if built.code != 0 || built.stdout != "" || built.stderr != "" {
		// A corpus program compiles. Whatever the compiler said about this one is the whole answer,
		// so it goes through as it was written and nothing is run.
		fmt.sbprintfln(
			job.report,
			"%v: %s: %s: the build answered %d",
			job.mode,
			path,
			level.flag,
			built.code,
		)
		fmt.sbprint(job.report, built.stdout)
		fmt.sbprint(job.report, built.stderr)
		return false
	}

	ok = true
	if job.sanitizer == .none &&
	   !compare_run(job, path, level.flag, run, environments.plain, want) {
		ok = false
	}
	stressed := fmt.tprintf("%s under GC stress", level.flag)
	if !compare_run(job, path, stressed, run, environments.stress, want) {
		ok = false
	}
	return ok
}

// compare_run names the run by label in what it reports: the level, and the stress mode if on.
@(private = "file")
compare_run :: proc(
	job: Job,
	path, label: string,
	run, environment: []string,
	want: Output,
) -> (
	ok: bool,
) {
	got := execute(job, path, run[0], run, environment) or_return
	ok = true
	if !same_stream(job, path, label, "stdout", got.stdout, want.stdout) {
		ok = false
	}
	if !same_stream(job, path, label, "stderr", got.stderr, want.stderr) {
		ok = false
	}
	if got.code != want.code {
		fmt.sbprintfln(
			job.report,
			"%v: %s: %s: exit code or signal: got %d, want %d",
			job.mode,
			path,
			label,
			got.code,
			want.code,
		)
		ok = false
	}
	return ok
}

// execute sends the output to files in dist/, not to pipes, which os.process_exec polls without
// pausing, keeping a core busy. A nil environment is the runner's own.
execute :: proc(
	job: Job,
	path, what: string,
	command: []string,
	environment: []string = nil,
) -> (
	output: Output,
	ok: bool,
) {
	stdout_path := fmt.tprintf("dist/%v-%d-stdout.txt", job.mode, job.worker)
	stderr_path := fmt.tprintf("dist/%v-%d-stderr.txt", job.mode, job.worker)
	flags := os.File_Flags{.Write, .Create, .Trunc, .Inheritable}
	stdout, stdout_err := os.open(stdout_path, flags)
	if stdout_err != nil {
		fmt.sbprintfln(job.report, "%v: create %s: %v", job.mode, stdout_path, stdout_err)
		return {}, false
	}
	defer os.close(stdout)
	stderr, stderr_err := os.open(stderr_path, flags)
	if stderr_err != nil {
		fmt.sbprintfln(job.report, "%v: create %s: %v", job.mode, stderr_path, stderr_err)
		return {}, false
	}
	defer os.close(stderr)

	description := os.Process_Desc {
		command = command,
		env     = environment,
		stdout  = stdout,
		stderr  = stderr,
	}
	process, start_err := os.process_start(description)
	if start_err != nil {
		fmt.sbprintfln(job.report, "%v: %s: run %s: %v", job.mode, path, what, start_err)
		return {}, false
	}
	state, wait_err := os.process_wait(process, TIME_LIMIT)
	if wait_err == .Timeout {
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
		fmt.sbprintfln(
			job.report,
			"%v: %s: %s ran past %v and was stopped",
			job.mode,
			path,
			what,
			TIME_LIMIT,
		)
		return {}, false
	}
	if wait_err != nil {
		fmt.sbprintfln(job.report, "%v: %s: wait for %s: %v", job.mode, path, what, wait_err)
		return {}, false
	}

	out, out_err := os.read_entire_file(stdout_path, context.temp_allocator)
	errors, errors_err := os.read_entire_file(stderr_path, context.temp_allocator)
	if out_err != nil || errors_err != nil {
		fmt.sbprintfln(
			job.report,
			"%v: %s: read the output of %s: %v, %v",
			job.mode,
			path,
			what,
			out_err,
			errors_err,
		)
		return {}, false
	}
	return Output{stdout = string(out), stderr = string(errors), code = state.exit_code}, true
}

// same_stream names only the first line where the two streams part: a corpus program prints a
// couple of dozen lines, and dumping both streams into a CI log buries the one that moved.
@(private = "file")
same_stream :: proc(job: Job, path, label, stream, got, want: string) -> bool {
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
		fmt.sbprintfln(
			job.report,
			"%v: %s: %s: %s line %d: got %s, want %s",
			job.mode,
			path,
			label,
			stream,
			index + 1,
			describe_line(got_lines, index),
			describe_line(want_lines, index),
		)
		return false
	}

	// Every line matched although the streams did not, which only a line ending can do:
	// split_lines makes nothing of the difference between "a\n" and "a\r\n".
	fmt.sbprintfln(
		job.report,
		"%v: %s: %s: %s: got %q, want %q",
		job.mode,
		path,
		label,
		stream,
		got,
		want,
	)
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
