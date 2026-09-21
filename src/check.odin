package main

import "core:fmt"

import "driver"

// check answers the process exit code of `tsnc check`.
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
