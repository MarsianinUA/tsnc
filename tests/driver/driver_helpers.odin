package driver_tests

import "core:fmt"
import "core:os"
import "core:testing"

import "../../src/diag"
import "../../src/driver"
import "../../src/source"
import "../../src/target"

// PROJECTS is found from this file's own location. The older test packages spell their paths
// relative to the repository root, which ties them to the directory the runner was started from;
// these tests read real files, so they ask the compiler instead.
PROJECTS :: #directory + "projects/"

// Error is a diagnostic the way a user reads it, with a 1-based line and column. The file is the
// name alone, since the directory the fixtures happen to sit in is not part of what the test is
// about.
Error :: struct {
	file:   string,
	code:   diag.Code,
	line:   i32,
	column: i32,
}

Checked :: struct {
	report: driver.Check_Report,
	err:    driver.Driver_Error,
	errors: []Error, // in print order, the order main prints them in
}

// Built holds a Check_Report inside its report, so the same errors_of serves both kinds of test.
Built :: struct {
	report: driver.Build_Report,
	err:    driver.Driver_Error,
	errors: []Error, // in print order, the order main prints them in
}

// RUNTIME_BUILD puts the runtime object where link looks for it: next to the running executable,
// which for these tests is the one `odin test` wrote. A test that links names this command when it
// fails, so a fresh clone gets the fix rather than a missing file.
RUNTIME_BUILD :: "odin build src/runtime -build-mode:obj -use-single-module -o:speed -out:dist/tsnc_rt-<target>.obj -vet -strict-style"

// check_project leaves the result to the caller, who must call driver.destroy on its report.
//
// Only input is filled in: check_only reads nothing else out of Options, and the fields that carry
// a target or a thread count first mean something in T4.5 and T6.1.
check_project :: proc(project, entry: string) -> Checked {
	options := driver.Options {
		command = .check,
		input   = fmt.tprintf("%s%s/%s", PROJECTS, project, entry),
	}
	report, err := driver.check_only(options)
	return {report = report, err = err, errors = errors_of(report)}
}

// out_path names a file a test writes, beside the test executable itself: `odin test tests/driver
// -out:dist/driver-tests.exe` puts that executable in dist/, which is also where link looks for the
// runtime object when the caller names none, so one directory serves both. Every test passes a name
// of its own, because the test runner runs them on a thread pool.
out_path :: proc(name: string) -> string {
	directory, _ := os.get_executable_directory(context.temp_allocator)
	path, _ := os.join_path({directory, name}, context.temp_allocator)
	return path
}

// build_options is what main would have parsed out of `tsnc build <fixture> -out:<name>`. A test
// that wants another artifact or another target sets the field afterwards.
build_options :: proc(project, entry, output: string) -> driver.Options {
	return {
		command = .build,
		input = fmt.tprintf("%s%s/%s", PROJECTS, project, entry),
		output = out_path(output),
		target = target.HOST,
	}
}

// build_project leaves the result to the caller, who must call driver.destroy on the Check_Report
// inside it.
build_project :: proc(options: driver.Options) -> Built {
	report, err := driver.build(options)
	return {report = report, err = err, errors = errors_of(report.check)}
}

expect_built :: proc(t: ^testing.T, b: Built, loc := #caller_location) -> bool {
	no_error := testing.expectf(
		t,
		b.err.kind == .None,
		"driver error %v: %s\nbuild the runtime object first: %s",
		b.err.kind,
		b.err.detail,
		RUNTIME_BUILD,
		loc = loc,
	)
	no_diagnostics := testing.expectf(t, len(b.errors) == 0, "errors %v", b.errors, loc = loc)
	wrote := testing.expectf(t, b.report.output != "", "nothing was written", loc = loc)
	return no_error && no_diagnostics && wrote
}

expect_clean :: proc(t: ^testing.T, c: Checked, loc := #caller_location) {
	testing.expectf(
		t,
		c.err.kind == .None,
		"driver error %v: %s",
		c.err.kind,
		c.err.detail,
		loc = loc,
	)
	testing.expectf(t, len(c.errors) == 0, "errors %v", c.errors, loc = loc)
}

// file_names answers in File_ID order.
file_names :: proc(c: Checked) -> []string {
	names := make([]string, len(c.report.program.files), context.temp_allocator)
	for file, i in c.report.program.files {
		names[i] = os.base(file.path)
	}
	return names
}

init_names :: proc(c: Checked) -> []string {
	return names_of(c, c.report.program.init_order)
}

cycle_names :: proc(c: Checked, cycle: int) -> []string {
	return names_of(c, c.report.program.cycles[cycle].modules)
}

@(private = "file")
names_of :: proc(c: Checked, modules: []source.File_ID) -> []string {
	names := make([]string, len(modules), context.temp_allocator)
	for module, i in modules {
		names[i] = os.base(c.report.program.files[module].path)
	}
	return names
}

@(private = "file")
errors_of :: proc(report: driver.Check_Report) -> []Error {
	errors := make([]Error, len(report.diagnostics), context.temp_allocator)
	for d, i in report.diagnostics {
		file := report.program.files[d.span.file]
		position := source.position(file, d.span.start)
		errors[i] = {os.base(file.path), d.code, position.line, position.column}
	}
	return errors
}
