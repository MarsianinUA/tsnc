package main

import "core:fmt"

import "driver"

// build answers the process exit code of `tsnc build`. A build that failed wrote nothing, so
// whatever stood at the output path before is still there.
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
