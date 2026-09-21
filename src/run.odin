package main

import "core:fmt"

import "driver"

// run answers the program's own exit code, so a program that exits with 3 makes tsnc exit with 3,
// and a build that failed exits with 1. The two cannot be told apart by the code alone when the
// program itself exits with 1, which is true of `node` and `odin run` as well; stderr tells them
// apart, because a program that does not compile always prints and a build that worked prints
// nothing.
run :: proc(options: driver.Options) -> int {
	report, err := driver.build(options)
	defer driver.destroy(&report.check)

	if err.kind != .None {
		fmt.eprintfln("tsnc: %s", error_text(err))
		return 1
	}
	if driver.has_errors(report.check) {
		print_diagnostics(report.check)
		return 1
	}

	code, run_err := driver.run(report)
	if run_err.kind != .None {
		fmt.eprintfln("tsnc: %s", error_text(run_err))
		return 1
	}
	return code
}
