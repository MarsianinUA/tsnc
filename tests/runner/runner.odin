/*
The test runner: one program with a mode per kind of run, started from the repository root:

	odin run tests/runner -out:dist/runner.exe -vet -strict-style -- smoke

smoke (T1.8) checks the infrastructure: codegen, link and the runtime object. negative (T2.9) and
diff (T4.7) join later. A mode prints what failed to stderr, and the runner exits with code 1.
*/
package main

import "core:flags"
import "core:log"
import "core:os"

// Mode values are lowercase because core:flags matches them against the command line by exact name.
Mode :: enum {
	smoke,
}

Options :: struct {
	mode: Mode `args:"pos=0,required" usage:"smoke"`,
}

main :: proc() {
	options: Options
	flags.parse_or_exit(&options, os.args, .Odin)

	// codegen explains LLVM failures through context.logger, and the default logger drops them.
	context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
	defer log.destroy_console_logger(context.logger)

	passed: bool
	switch options.mode {
	case .smoke:
		passed = smoke()
	}
	if !passed {
		os.exit(1)
	}
}
