/*
The test runner: one program with a mode per kind of run, started from the repository root:

	odin run tests/runner -out:dist/runner.exe -vet -strict-style -- smoke

smoke (T1.8) checks the infrastructure: codegen, link and the runtime object. negative (T2.9) runs
the corpus in tests/negative/, where every program must fail to compile the way its header says.
diff (T4.7) runs the corpus in tests/diff/, where every program must print what Node prints. A mode
prints what failed to stderr, and the runner exits with code 1.
*/
package main

import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"

// Mode values are lowercase because core:flags matches them against the command line by exact name.
Mode :: enum {
	smoke,
	negative,
	diff,
}

Options :: struct {
	mode: Mode `args:"pos=0,required" usage:"smoke, negative or diff"`,
}

// COMPILER and the path in COMPILER_BUILD are relative to the current directory, as smoke's dist/
// paths already are: the runner is started from the repository root. smoke needs neither, since it
// calls codegen and link itself.
COMPILER :: "dist/tsnc.exe"
COMPILER_BUILD :: "odin build src -out:dist/tsnc.exe -o:speed -vet -strict-style"

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
	case .negative:
		passed = negative()
	case .diff:
		passed = diff()
	}
	if !passed {
		os.exit(1)
	}
}

// compiler_path answers an absolute path, so that running it does not depend on how the OS resolves
// a relative one, as smoke already found. A mode that cannot find the compiler prints the command
// that builds it, so a fresh clone gets the fix rather than a riddle.
compiler_path :: proc(mode: string) -> (path: string, ok: bool) {
	if !os.is_file(COMPILER) {
		fmt.eprintfln("%s: %s is missing", mode, COMPILER)
		fmt.eprintln("run the runner from the repository root, and build the compiler first:")
		fmt.eprintfln("  %s", COMPILER_BUILD)
		return "", false
	}

	absolute, err := os.get_absolute_path(COMPILER, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("%s: absolute path of %s: %v", mode, COMPILER, err)
		return "", false
	}
	return absolute, true
}
