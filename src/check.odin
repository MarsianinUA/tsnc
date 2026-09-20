package main

import "core:bufio"
import "core:fmt"
import "core:os"

import "diag"
import "driver"

// check runs `tsnc check` and answers with the process exit code: 0 when the program has no
// errors, 1 when it has any. It writes nothing to stdout, so the diagnostics of a build never mix
// with the output of a program under `tsnc run`.
check :: proc(options: driver.Options) -> int {
	report, err := driver.check_only(options)
	defer driver.destroy(&report)

	if err.kind != .None {
		fmt.eprintfln("tsnc: %s", error_text(err))
		return 1
	}
	if !driver.has_errors(report) {
		return 0
	}
	print_diagnostics(report)
	return 1
}

// print_diagnostics writes the diagnostics to stderr through one buffered writer, since rendering
// each of them is a dozen small writes.
print_diagnostics :: proc(report: driver.Check_Report) {
	buf: [4096]byte
	stderr: bufio.Writer
	bufio.writer_init_with_buf(&stderr, os.to_writer(os.stderr), buf[:])

	w := bufio.writer_to_writer(&stderr)
	for d in report.diagnostics {
		// When stderr itself fails there is nobody left to tell: the exit code still says it.
		_ = diag.render(w, report.program.files, d)
	}
	_ = bufio.writer_flush(&stderr)
}

// error_text is the one line a failure that stopped the build before it started prints as.
error_text :: proc(err: driver.Driver_Error) -> string {
	switch err.kind {
	case .None:
		return ""
	case .Entry_Unreadable:
		return fmt.tprintf("cannot read %s", err.detail)
	case .Entry_Too_Large:
		return fmt.tprintf("%s is larger than a compile unit can address", err.detail)
	case .Out_Of_Memory:
		return "out of memory"
	}
	return ""
}
