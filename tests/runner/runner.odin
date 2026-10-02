/*
The test runner: one program with a mode per kind of run, started from the repository root:

	odin build tests/runner -out:dist/runner.exe -vet -strict-style
	dist/runner.exe smoke

unit runs `odin test` on every package under tests/. smoke checks the infrastructure: codegen, link
and the runtime object. negative runs the corpus in tests/negative/, where every program must fail
to compile the way its header says. diff runs the corpus in tests/diff/, where every program must
print what Node prints. expect runs the corpus in tests/expect/, where every program must print what
its header says. docs/development.md has a section on each corpus. A mode prints what failed to
stderr, and the runner exits with code 1.

Every mode but smoke runs its programs in parallel, -j of them at a time.
*/
package main

import "base:runtime"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"

import "../../src/link"

// Mode values are lowercase because core:flags matches them against the command line by exact name.
Mode :: enum {
	unit,
	smoke,
	negative,
	diff,
	expect,
}

Options :: struct {
	mode:     Mode `args:"pos=0,required" usage:"unit, smoke, negative, diff or expect"`,
	sanitize: link.Sanitizer `usage:"diff, expect: link the runtime built with -sanitize:address"`,
	jobs:     int `args:"name=j" usage:"programs run at a time (default: number of cores)"`,
}

// COMPILER and the path in COMPILER_BUILD are relative to the current directory, as smoke's dist/
// paths already are: the runner is started from the repository root. smoke needs neither, since it
// calls codegen and link itself.
COMPILER :: "dist/tsnc.exe"
COMPILER_BUILD :: "odin build src -out:dist/tsnc.exe -o:speed -vet -strict-style"

main :: proc() {
	options := Options {
		jobs = os.get_processor_core_count(),
	}
	flags.parse_or_exit(&options, os.args, .Odin)
	if options.jobs < 1 {
		fmt.eprintfln("-j:%d: a run needs at least one thread", options.jobs)
		os.exit(1)
	}

	// codegen explains LLVM failures through context.logger, and the default logger drops them.
	context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
	defer log.destroy_console_logger(context.logger)

	passed: bool
	switch options.mode {
	case .unit:
		passed = unit(options.jobs)
	case .smoke:
		passed = smoke()
	case .negative:
		passed = negative(options.jobs)
	case .diff:
		passed = run_corpus(.diff, DIFF_CORPUS, options.sanitize, options.jobs, diff_program)
	case .expect:
		passed = run_corpus(.expect, EXPECT_CORPUS, options.sanitize, options.jobs, expect_program)
	}
	if !passed {
		os.exit(1)
	}
}

// Job is what a program gets from the thread that runs it.
Job :: struct {
	mode:      Mode,
	compiler:  string,
	dist:      string,
	sanitizer: link.Sanitizer,
	worker:    int, // names the files execute sends a child's output to
	report:    ^strings.Builder, // what failed, printed once every program ran
}

// Program answers what it counted for the summary line, such as the diagnostics of negative.
Program :: proc(job: Job, path: string) -> (count: int, ok: bool)

// run_programs prints the reports in the order of paths, so a log reads the same however the
// threads ran.
run_programs :: proc(
	template: Job,
	paths: []string,
	jobs: int,
	program: Program,
) -> (
	count: int,
	passed: bool,
) {
	work := Work {
		template = template,
		paths    = paths,
		program  = program,
		outcomes = make([]Outcome, len(paths), context.temp_allocator),
	}
	threads := make([]^thread.Thread, clamp(jobs, 1, len(paths)), context.temp_allocator)
	for &worker, index in threads {
		worker = thread.create_and_start_with_poly_data2(&work, index, run_paths)
	}
	thread.join_multiple(..threads)
	for worker in threads {
		thread.destroy(worker)
	}

	passed = true
	for &outcome in work.outcomes {
		fmt.eprint(strings.to_string(outcome.report))
		strings.builder_destroy(&outcome.report)
		count += outcome.count
		if !outcome.ok {
			passed = false
		}
	}
	return count, passed
}

@(private = "file")
Outcome :: struct {
	report: strings.Builder,
	count:  int,
	ok:     bool,
}

@(private = "file")
Work :: struct {
	template: Job,
	paths:    []string,
	program:  Program,
	outcomes: []Outcome,
	next:     int, // the index of the next path a thread takes
}

// run_paths runs on a thread of its own, so its context is a fresh one: its temp allocator and the
// heap allocator the reports take are that thread's.
@(private = "file")
run_paths :: proc(work: ^Work, worker: int) {
	for {
		index := sync.atomic_add(&work.next, 1)
		if index >= len(work.paths) {
			return
		}
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		outcome := &work.outcomes[index]
		outcome.report = strings.builder_make()
		job := work.template
		job.worker = worker
		job.report = &outcome.report
		outcome.count, outcome.ok = work.program(job, work.paths[index])
	}
}

// compiler_path answers an absolute path, so that running it does not depend on how the OS resolves
// a relative one, as smoke already found. A mode that cannot find the compiler prints the command
// that builds it, so a fresh clone gets the fix rather than a riddle.
compiler_path :: proc(mode: Mode) -> (path: string, ok: bool) {
	if !os.is_file(COMPILER) {
		fmt.eprintfln("%v: %s is missing", mode, COMPILER)
		fmt.eprintln("run the runner from the repository root, and build the compiler first:")
		fmt.eprintfln("  %s", COMPILER_BUILD)
		return "", false
	}

	absolute, err := os.get_absolute_path(COMPILER, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("%v: absolute path of %s: %v", mode, COMPILER, err)
		return "", false
	}
	return absolute, true
}
