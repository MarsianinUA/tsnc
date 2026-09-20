package main

import "core:fmt"

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
