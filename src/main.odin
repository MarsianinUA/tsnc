package main

import "core:flags"
import "core:fmt"
import "core:os"

import "driver"
import "target"

main :: proc() {
	options := driver.Options {
		optimization = .speed,
		target       = target.HOST,
		jobs         = os.get_processor_core_count(),
	}
	flags.parse_or_exit(&options, os.args, .Odin)

	// stderr only: stdout belongs to the compiled program under `tsnc run`.
	// core:flags accepts every Target value, and a declared target may have no SPECS row yet.
	if !target.supported(options.target) {
		fmt.eprintfln("target %v is not supported yet", options.target)
		os.exit(1)
	}

	// One file per command: check.odin holds this one, build and run join it in T4.5. No default
	// case, so a command added then fails the build here until it is handled.
	switch options.command {
	case .check:
		os.exit(check(options))
	case .build, .run:
		fmt.eprintfln("tsnc %v: not implemented", options.command)
		os.exit(1)
	}
}
