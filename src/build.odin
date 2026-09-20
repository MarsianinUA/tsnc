package main

import "core:fmt"

import "driver"

// build runs `tsnc build` and answers with the process exit code: 0 once the artifact is on disk,
// 1 for a program that does not compile and for every failure that stopped the build before it
// could say anything about the program. A build that failed wrote nothing, so whatever stood at
// the output path before is still there.
build :: proc(options: driver.Options) -> int {
	report, err := driver.build(options)
	defer driver.destroy(&report.check)

	if err.kind != .None {
		fmt.eprintfln("tsnc: %s", error_text(err))
		return 1
	}
	if !driver.has_errors(report.check) {
		return 0
	}
	print_diagnostics(report.check)
	return 1
}
