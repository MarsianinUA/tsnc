package main

import "core:bufio"
import "core:fmt"
import "core:os"

import "diag"
import "driver"

// What every command prints. All three write to stderr alone, so that the diagnostics of a build
// never mix with the output of a program under `tsnc run`, and only main prints at all: a phase
// answers with data and driver answers with a report.

// print_diagnostics goes through one buffered writer, since rendering each diagnostic is a dozen
// small writes.
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

// error_text gives a failure a user can act on its next step on a hint line, the shape diag.render
// already gives a diagnostic. The switch has no default, so an error kind added to driver fails the
// build here until it has a sentence.
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
	case .Two_Artifacts:
		return "-emit-llvm and -emit-ir name two different files\n  hint: pass one of them"
	case .Nothing_To_Run:
		return NOTHING_TO_RUN
	case .Cross_Link:
		return CROSS_LINK
	case .Output_Unnamable:
		return fmt.tprintf("cannot name the output after %s\n  hint: pass -out:", err.detail)
	case .Output_Is_Source:
		return fmt.tprintf(
			"cannot write %s: it is a source file of the program\n  hint: pass another -out:",
			err.detail,
		)
	case .Output_Directory_Missing:
		return fmt.tprintf("there is no directory %s", err.detail)
	case .Broken_IR:
		return fmt.tprintf(
			"internal error: the IR broke its own contract, which is a bug in tsnc\n%s",
			err.detail,
		)
	case .Codegen_Failed:
		return fmt.tprintf("cannot generate code for %s", err.detail)
	case .Runtime_Object_Missing:
		return fmt.tprintf(
			"the runtime object %s is missing\n  hint: %s",
			err.detail,
			RUNTIME_BUILD,
		)
	case .Sanitized_Runtime_Missing:
		return fmt.tprintf(
			"the runtime object %s is missing\n  hint: %s",
			err.detail,
			SANITIZED_RUNTIME_BUILD,
		)
	case .Sanitizer_Unsupported:
		return "-sanitize:address works on Windows and Linux only"
	case .Link_Failed:
		return fmt.tprintf("cannot link the program: %s", err.detail)
	case .Output_Unwritable:
		return fmt.tprintf("cannot write %s", err.detail)
	case .Program_Unrunnable:
		return fmt.tprintf("cannot run %s", err.detail)
	}
	return ""
}

// The messages too long to sit inside the switch. A string literal is the one thing the formatter
// cannot wrap, so the long ones live here and the switch stays a table of one line per kind.

@(private = "file")
NOTHING_TO_RUN :: "tsnc run builds a program and runs it, while -emit-llvm and -emit-ir write a file\n  hint: `tsnc build` writes those"

@(private = "file")
CROSS_LINK :: "v1 builds a program for this machine only\n  hint: -emit-llvm and -emit-ir work for any -target:"

// RUNTIME_BUILD is the command that puts the runtime object where link looks for it. It is the one
// failure of a fresh clone that a user fixes by running one line, so the line is in the message.
@(private = "file")
RUNTIME_BUILD :: "odin build src/runtime -build-mode:obj -use-single-module -o:speed -out:dist/tsnc_rt-<target>.obj -vet -strict-style"

@(private = "file")
SANITIZED_RUNTIME_BUILD :: "odin build src/runtime -build-mode:obj -use-single-module -o:speed -sanitize:address -out:dist/tsnc_rt-<target>-asan.obj -vet -strict-style"
