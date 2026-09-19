package driver_tests

import "core:fmt"
import "core:os"
import "core:testing"

import "../../src/diag"
import "../../src/driver"
import "../../src/source"

// PROJECTS is where the fixture programs live, found from this file's own location. The older test
// packages spell their paths relative to the repository root, which ties them to the directory the
// runner was started from; these tests read real files, so they ask the compiler instead.
PROJECTS :: #directory + "projects/"

// Error is a diagnostic the way a user reads it: which file it is in, its code, and the 1-based
// line and column where it starts. The file is the name alone, since the directory the fixtures
// happen to sit in is not part of what the test is about.
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

// check_project runs `tsnc check` over one fixture program, the way main does. The caller owns the
// result and must call driver.destroy on its report.
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

// expect_clean checks a program that must produce no diagnostic at all.
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

// file_names lists the files of the program in File_ID order, by name.
file_names :: proc(c: Checked) -> []string {
	names := make([]string, len(c.report.files), context.temp_allocator)
	for file, i in c.report.files {
		names[i] = os.base(file.path)
	}
	return names
}

@(private = "file")
errors_of :: proc(report: driver.Check_Report) -> []Error {
	errors := make([]Error, len(report.diagnostics), context.temp_allocator)
	for d, i in report.diagnostics {
		file := report.files[d.span.file]
		position := source.position(file, d.span.start)
		errors[i] = {os.base(file.path), d.code, position.line, position.column}
	}
	return errors
}
