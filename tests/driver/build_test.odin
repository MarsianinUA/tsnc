package driver_tests

import "core:os"
import "core:strings"
import "core:testing"

import "../../src/driver"
import "../../src/target"

/*
The pipeline of T4.5: check, lower, verify, codegen, link, and the program at the end of it.

Every test writes beside the test executable under a name of its own, because the test runner runs
them on a thread pool. The tests that link need the runtime object in that same directory;
expect_built names the command that puts it there when they fail.

The fixture `loops` is the done criterion of the task: numbers and loops, answering through a
boolean and an exit code. Printed numbers are checked against Node itself, in the differential
corpus of T4.7, and not here.
*/

@(test)
the_ir_dump_is_written :: proc(t: ^testing.T) {
	options := build_options("loops", "main.ts", "driver-loops.ir")
	options.emit_ir = true
	built := build_project(options)
	defer driver.destroy(&built.report.check)
	if !expect_built(t, built) {
		return
	}

	testing.expect_value(t, built.report.artifact, driver.Artifact.IR_Dump)
	text := read_artifact(t, built.report.output)
	testing.expectf(t, strings.has_prefix(text, "; tsnc ir"), "the dump opens with %.20q", text)
	testing.expect(t, strings.contains(text, "tsnc_main"), "the dump has no entry point")
	expect_no_leftovers(t, built.report.output)
}

@(test)
textual_llvm_ir_is_written :: proc(t: ^testing.T) {
	options := build_options("loops", "main.ts", "driver-loops.ll")
	options.emit_llvm = true
	built := build_project(options)
	defer driver.destroy(&built.report.check)
	if !expect_built(t, built) {
		return
	}

	testing.expect_value(t, built.report.artifact, driver.Artifact.LLVM_IR)
	text := read_artifact(t, built.report.output)
	testing.expect(t, strings.contains(text, "define"), "the module defines no function")
	triple := string(target.SPECS[target.HOST].triple)
	testing.expectf(t, strings.contains(text, triple), "the module is not for %s", triple)
	expect_no_leftovers(t, built.report.output)
}

// The whole chain, through the linker and out the other side. os.process_exec rather than
// driver.run, because run hands the program tsnc's own streams and its output would land in the
// test log; run_passes_on_the_exit_code covers run itself.
@(test)
an_executable_is_built_and_runs :: proc(t: ^testing.T) {
	built := build_project(build_options("loops", "main.ts", "driver-loops.exe"))
	defer driver.destroy(&built.report.check)
	if !expect_built(t, built) {
		return
	}

	testing.expect_value(t, built.report.artifact, driver.Artifact.Executable)
	expect_no_leftovers(t, built.report.output)

	state, stdout, stderr, run_err := os.process_exec(
		{command = {built.report.output}},
		context.allocator,
	)
	defer delete(stdout)
	defer delete(stderr)
	if !testing.expectf(t, run_err == nil, "run %s: %v", built.report.output, run_err) {
		return
	}
	// The program sums 1 to 10, says whether that is 55, and leaves the remainder as its code.
	testing.expect_value(t, string(stdout), "true\n")
	testing.expect_value(t, string(stderr), "")
	testing.expect_value(t, state.exit_code, 6)
}

// driver.run itself. The fixture prints nothing, so inherited stdio leaves the test log alone and
// the exit code is the whole answer.
@(test)
run_passes_on_the_exit_code :: proc(t: ^testing.T) {
	options := build_options("exit", "main.ts", "driver-exit.exe")
	options.command = .run
	built := build_project(options)
	defer driver.destroy(&built.report.check)
	if !expect_built(t, built) {
		return
	}

	code, run_err := driver.run(built.report)
	testing.expectf(t, run_err.kind == .None, "%v: %s", run_err.kind, run_err.detail)
	testing.expect_value(t, code, 7)
}

// The rename replaces whatever stood at the path, and a build that fails leaves it alone: that is
// what "atomic at the artifact level" has to mean to be worth anything.
@(test)
a_failed_build_leaves_the_program_that_was_there :: proc(t: ^testing.T) {
	first := build_project(build_options("loops", "main.ts", "driver-replaced.exe"))
	defer driver.destroy(&first.report.check)
	if !expect_built(t, first) {
		return
	}

	options := build_options("types", "main.ts", "driver-replaced.exe")
	second := build_project(options)
	defer driver.destroy(&second.report.check)
	testing.expectf(t, second.err.kind == .None, "%v: %s", second.err.kind, second.err.detail)
	testing.expect(t, len(second.errors) > 0, "the program types with no error")
	testing.expect_value(t, second.report.output, "")

	state, stdout, _, run_err := os.process_exec({command = {options.output}}, context.allocator)
	defer delete(stdout)
	if !testing.expectf(t, run_err == nil, "run %s: %v", options.output, run_err) {
		return
	}
	testing.expect_value(t, string(stdout), "true\n")
	testing.expect_value(t, state.exit_code, 6)
	expect_no_leftovers(t, options.output)
}

@(test)
a_program_with_errors_never_reaches_lower :: proc(t: ^testing.T) {
	options := build_options("types", "main.ts", "driver-types.exe")
	built := build_project(options)
	defer driver.destroy(&built.report.check)

	testing.expectf(t, built.err.kind == .None, "%v: %s", built.err.kind, built.err.detail)
	testing.expect(t, len(built.errors) > 0, "the program types with no error")
	testing.expect_value(t, built.report.output, "")
	testing.expectf(t, !os.exists(options.output), "%s was written", options.output)
}

// The command line is read before any file is: the entry file here does not exist, and the answer
// is still about the flags.
@(test)
a_contradictory_command_line_is_refused_first :: proc(t: ^testing.T) {
	// -out: names one file, and these ask for two.
	two := build_options("nowhere", "not-here.ts", "driver-refused")
	two.emit_llvm, two.emit_ir = true, true
	built_two := build_project(two)
	defer driver.destroy(&built_two.report.check)
	testing.expect_value(t, built_two.err.kind, driver.Error_Kind.Two_Artifacts)

	// A dump is not a program, so there is nothing for `tsnc run` to start.
	nothing := build_options("nowhere", "not-here.ts", "driver-refused")
	nothing.command, nothing.emit_ir = .run, true
	built_nothing := build_project(nothing)
	defer driver.destroy(&built_nothing.report.check)
	testing.expect_value(t, built_nothing.err.kind, driver.Error_Kind.Nothing_To_Run)
}

// v1 links for the host alone, and that is decided before the program is read. The same target
// still writes an IR dump, which needs no linker and no LLVM back end for it.
@(test)
only_the_host_target_builds_a_program :: proc(t: ^testing.T) {
	for id in target.Target {
		if id == target.HOST || !target.supported(id) {
			continue
		}

		options := build_options("loops", "main.ts", "driver-cross.exe")
		options.target = id
		refused := build_project(options)
		defer driver.destroy(&refused.report.check)
		testing.expectf(t, refused.err.kind == .Cross_Link, "%v: %v", id, refused.err.kind)

		options = build_options("loops", "main.ts", "driver-cross.ir")
		options.target = id
		options.emit_ir = true
		built := build_project(options)
		defer driver.destroy(&built.report.check)
		testing.expectf(t, built.err.kind == .None, "%v: %v", id, built.err.kind)
	}
}

@(test)
a_missing_output_directory_is_reported :: proc(t: ^testing.T) {
	options := build_options("clean", "main.ts", "driver-no-such-dir/app.exe")
	built := build_project(options)
	defer driver.destroy(&built.report.check)

	testing.expect_value(t, built.err.kind, driver.Error_Kind.Output_Directory_Missing)
	testing.expectf(
		t,
		strings.has_suffix(built.err.detail, "driver-no-such-dir"),
		"detail %q",
		built.err.detail,
	)
	testing.expectf(t, !os.exists(options.output), "%s was written", options.output)
}

// Without -out: the name comes from the entry file's stem and the artifact, in the current
// directory. The fixture is named for this test alone, so that the three files it leaves in the
// working directory for a moment are recognisably its own; they are removed as it goes.
@(test)
the_default_output_is_named_after_the_entry_file :: proc(t: ^testing.T) {
	Case :: struct {
		emit_llvm: bool,
		emit_ir:   bool,
		suffix:    string,
	}
	cases := [?]Case {
		{suffix = target.SPECS[target.HOST].executable_suffix},
		{emit_llvm = true, suffix = ".ll"},
		{emit_ir = true, suffix = ".ir"},
	}
	for c in cases {
		options := build_options("default-name", "driver-default.ts", "")
		options.output = ""
		options.emit_llvm, options.emit_ir = c.emit_llvm, c.emit_ir
		built := build_project(options)
		defer driver.destroy(&built.report.check)
		if !expect_built(t, built) {
			continue
		}
		want := strings.concatenate({"driver-default", c.suffix}, context.temp_allocator)
		testing.expect_value(t, built.report.output, want)
		testing.expectf(t, os.exists(want), "%s was not written", want)
		_ = os.remove(built.report.output)
	}
}

// read_artifact answers what a build wrote, and an empty string with a message when it wrote
// nothing a test can read.
@(private = "file")
read_artifact :: proc(t: ^testing.T, path: string, loc := #caller_location) -> string {
	text, err := os.read_entire_file(path, context.temp_allocator)
	if !testing.expectf(t, err == nil, "read %s: %v", path, err, loc = loc) {
		return ""
	}
	return string(text)
}

// expect_no_leftovers checks that the build left nothing beside its artifact: the temporary file
// it wrote before the rename, and the object file an executable passes through, both carry the
// artifact's name and a process id.
//
// It walks the directory rather than reading it whole. Every test here writes into the one
// directory beside the test executable and the runner runs them on a thread pool, so another test's
// build renames its own `<output>.<pid>.tmp` into place while this walk is going. That entry is
// gone by the time the walk stats it, and read_all_directory_by_path turns the one missing entry
// into a failure of the whole read: on the arm64 CI runner it read as "dist: Not_Exist", as though
// the directory itself were missing. An entry that vanishes is never the one being checked, since
// every test names its artifact differently, so the walk passes over it.
@(private = "file")
expect_no_leftovers :: proc(t: ^testing.T, artifact: string, loc := #caller_location) {
	directory := os.dir(artifact)
	handle, open_err := os.open(directory)
	if !testing.expectf(t, open_err == nil, "open %s: %v", directory, open_err, loc = loc) {
		return
	}
	defer os.close(handle)

	it := os.read_directory_iterator_create(handle)
	defer os.read_directory_iterator_destroy(&it)

	name := os.base(artifact)
	for entry in os.read_directory_iterator(&it) {
		// An entry the walk could not stat arrives empty, and no name of ours matches that.
		if entry.name == name || !strings.has_prefix(entry.name, name) {
			continue
		}
		testing.expectf(t, false, "%s was left behind", entry.name, loc = loc)
	}
}
