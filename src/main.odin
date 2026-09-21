package main

import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"

import "driver"
import "target"

main :: proc() {
	options := driver.Options {
		optimization = .speed,
		target       = target.HOST,
		jobs         = os.get_processor_core_count(),
	}
	flags.parse_or_exit(&options, command_line(), .Odin)

	// codegen explains an LLVM failure through context.logger, and the default logger drops it. A
	// file logger on stderr rather than a console logger: the console logger sends anything below
	// Error to stdout, and stdout belongs to the program under `tsnc run`. It is never destroyed,
	// because destroy_file_logger closes the handle it was given and that handle is stderr. The
	// empty options leave out the level banner and the timestamp, so a message arrives as the
	// sentence codegen already wrote.
	context.logger = log.create_file_logger(os.stderr, opt = log.Options{})

	// stderr only: stdout belongs to the compiled program under `tsnc run`.
	// core:flags accepts every Target value, and a declared target may have no SPECS row yet.
	if !target.supported(options.target) {
		fmt.eprintfln("target %v is not supported yet", options.target)
		os.exit(1)
	}

	// One file per command: check.odin, build.odin and run.odin, with report.odin holding what all
	// three print. No default case, so a command added later fails the build here until it is
	// handled.
	switch options.command {
	case .check:
		os.exit(check(options))
	case .build:
		os.exit(build(options))
	case .run:
		os.exit(run(options))
	}
}

// command_line is the arguments tsnc was started with, in UTF-8. os.args is the narrow argv of the C
// runtime, which Windows fills in the ANSI code page, so a path with Cyrillic letters in it named no
// file. core:os reads the wide command line for a process info instead, and only when asked for both
// fields at once. The arguments live as long as the process, like os.args.
@(private = "file")
command_line :: proc() -> []string {
	when ODIN_OS == .Windows {
		info, _ := os.current_process_info({.Command_Line, .Command_Args}, context.allocator)
		if .Command_Args in info.fields {
			return info.command_args
		}
	}
	return os.args
}
