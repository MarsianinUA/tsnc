/*
Everything after check: the rest of the pipeline, and running what came out of it.

build is the whole compiler in one call. It runs check_only, stops while the program still has a
mistake in it, lowers the typed program to IR, puts that IR through the verifier, and writes the one
artifact the command line asked for: the tsnc IR dump of -emit-ir, the textual LLVM IR of
-emit-llvm, or an executable through codegen and link. run starts the program build wrote and
answers its exit code.

Atomicity. An artifact is written into a temporary directory and renamed into place once it is
whole, so whoever reads the output path sees either the program that was there before or the new
one, never half of either. The directory sits beside the target rather than in the system temp
directory, because a rename across volumes is a copy and not an atomic replacement. An executable
needs an object file on the way, and that object is written into the same directory and goes with
it: requirements 9 lists an object file as an artifact only on request, and no flag asks for one.

Errors. codegen and link each answer with an enum of their own, and build turns them into a
Driver_Error whose detail is a sentence a user can act on, which is the rule for an infrastructure
failure. Every detail is allocated in the report's memory and dies with it.

Memory. lower gets an arena of its own, the phase arena of Build_Memory, holding the Program_IR and
whatever lower had to say about the program. Paths and error texts go into the driver arena beside
the file table. Everything else is scratch from context.temp_allocator, which build does not rewind:
lower and ir.verify each say that resetting their scratch belongs to whoever owns the frame, and
T6.2 settles it for every phase at once, once every phase has a thread of its own. One build then
exits, so nothing accumulates; the test runner frees the scratch between tests.
*/
package driver

import "base:runtime"
import "core:bufio"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:time"

import "../codegen"
import "../diag"
import "../ir"
import "../link"
import "../lower"
import "../program"
import "../source"
import "../target"

// OBJECT_SUFFIX is `.obj` on every platform, the spelling target.SPECS already gives the runtime
// object, because the system C compiler reads a file's role from its extension on Linux and macOS
// and link hands it a `.obj` there on every smoke run.
@(private = "file")
OBJECT_SUFFIX :: ".obj"

// build answers everything it learned; main prints the diagnostics and turns the answer into an
// exit code. Three endings are possible: an error, which stopped the build before it could say
// anything about the program; a report with diagnostics and an empty output, which is a program
// that does not compile; and a report with an output, which is the artifact on disk.
@(require_results)
build :: proc(
	options: Options,
	allocator := context.allocator,
) -> (
	report: Build_Report,
	err: Driver_Error,
) {
	// The command line is read first, so that a contradictory one costs no work at all: none of
	// these answers needs a file to have been opened.
	artifact: Artifact
	if artifact, err = artifact_of(options); err.kind != .None {
		return {}, err
	}
	report.artifact = artifact

	if report.check, err = check_only(options, allocator); err.kind != .None {
		return report, err
	}
	if has_errors(report.check) {
		return report, {}
	}

	memory := report.check.memory
	arena := virtual.arena_allocator(&memory.arena)

	// --- Lower, into the phase arena that holds the IR for the rest of the build.
	if virtual.arena_init_growing(&memory.lowering) != nil {
		return report, {kind = .Out_Of_Memory}
	}
	lowering := virtual.arena_allocator(&memory.lowering)
	program_ir, lower_diagnostics := lower.lower(
		&report.check.program,
		report.check.results,
		lowering,
	)
	if len(lower_diagnostics) > 0 {
		// The gate above left the report's list empty, so there is nothing to merge these with:
		// sorting lower's own diagnostics is the whole of print order here.
		diag.sort(lower_diagnostics)
		report.check.diagnostics = lower_diagnostics
		return report, {}
	}

	// --- Verify. codegen relies on what the verifier promises and does not check again, so a
	// broken instruction is caught here, where it can still be named, instead of inside LLVM.
	if violations := ir.verify(program_ir, lowering); len(violations) > 0 {
		text := violations_text(report.check.program.files, program_ir, violations, arena)
		return report, {.Broken_IR, text}
	}

	// --- Where the artifact goes, and whether it can go there. LLVM says nothing useful about a
	// path it could not open, and one check covers all three artifacts.
	output: string
	if output, err = output_path(options, artifact, arena); err.kind != .None {
		return report, err
	}
	if source_path, is_source := source_at(output, report.check.program.files); is_source {
		return report, {.Output_Is_Source, strings.clone(source_path, arena)}
	}
	if directory := os.dir(output); directory != "" && directory != "." && !os.is_dir(directory) {
		return report, {.Output_Directory_Missing, strings.clone(directory, arena)}
	}

	// --- Write it into a directory of its own beside the target, then rename it into place. The
	// directory is new, so removing it with whatever is left inside removes only this build's files.
	paths := artifact_paths(output, arena)
	if make_err := os.make_directory(paths.directory); make_err != nil {
		return report, {.Output_Unwritable, reason_text(output, make_err, arena)}
	}
	defer remove_directory(paths.directory)

	switch artifact {
	case .IR_Dump:
		err = write_dump(paths, report.check.program.files, program_ir, arena)
	case .LLVM_IR:
		err = run_codegen(&program_ir, options, .LLVM_IR, paths, arena)
	case .Executable:
		err = build_executable(&program_ir, options, paths, arena)
	}
	if err.kind != .None {
		return report, err
	}
	if rename_err := rename_into_place(paths); rename_err != nil {
		return report, {.Output_Unwritable, reason_text(output, rename_err, arena)}
	}

	report.output = output
	return report, {}
}

// run answers the program's exit code, so `tsnc run` is as transparent as node: a program that
// exits with 3 makes tsnc exit with 3. A program that crashed comes back as whatever the OS
// reported, the same number tests/runner/smoke.odin prints.
@(require_results)
run :: proc(report: Build_Report) -> (code: int, err: Driver_Error) {
	ensure(report.output != "", "run needs the artifact of a build that wrote one")
	arena := virtual.arena_allocator(&report.check.memory.arena)

	// An absolute path: a bare name with no directory in it is looked for on PATH rather than in
	// the current directory, which is what the smoke test found before this existed.
	path, path_err := os.get_absolute_path(report.output, context.temp_allocator)
	if path_err != nil {
		return 1, {.Program_Unrunnable, reason_text(report.output, path_err, arena)}
	}

	// A nil stream in Process_Desc shuts that stream down rather than inheriting it, so all three
	// handles are passed: the program reads and writes exactly what tsnc itself does.
	process, start_err := os.process_start(
		{command = {path}, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr},
	)
	if start_err != nil {
		return 1, {.Program_Unrunnable, reason_text(path, start_err, arena)}
	}

	// process_wait closes the handle as well as waiting on it; there is nothing else to release.
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		return 1, {.Program_Unrunnable, reason_text(path, wait_err, arena)}
	}
	return state.exit_code, {}
}

@(private = "file")
artifact_of :: proc(options: Options) -> (artifact: Artifact, err: Driver_Error) {
	switch {
	case options.emit_llvm && options.emit_ir:
		return {}, {kind = .Two_Artifacts}
	case options.emit_llvm:
		artifact = .LLVM_IR
	case options.emit_ir:
		artifact = .IR_Dump
	case:
		artifact = .Executable
	}
	if options.command == .run && artifact != .Executable {
		return {}, {kind = .Nothing_To_Run}
	}
	// link builds for the host alone in v1, so there is no executable for another platform. Its
	// LLVM IR and its IR dump there are fine, and that is what -target: is good for until v2.
	if artifact == .Executable && options.target != target.HOST {
		return {}, {kind = .Cross_Link}
	}
	return artifact, {}
}

// output_path takes -out: exactly as it was written; without it the name comes from the entry
// file, in the current directory, the way `odin build x.odin -file` leaves x.exe where it was
// started.
@(private = "file")
output_path :: proc(
	options: Options,
	artifact: Artifact,
	allocator: runtime.Allocator,
) -> (
	path: string,
	err: Driver_Error,
) {
	if options.output != "" {
		return strings.clone(options.output, allocator), {}
	}

	suffix: string
	switch artifact {
	case .Executable:
		suffix = target.SPECS[options.target].executable_suffix
	case .LLVM_IR:
		suffix = ".ll"
	case .IR_Dump:
		suffix = ".ir"
	}
	stem := os.stem(options.input)
	path = strings.concatenate({stem, suffix}, allocator)

	// Two ways a derived name is no name at all. An entry file with no stem, `.ts` or a directory,
	// leaves the suffix alone; and an executable has no suffix outside Windows, so `tsnc build
	// main` would derive the entry file itself. A compiler that writes over its own input is worse
	// than one that asks for -out:.
	if stem == "" || names_one_file(path, options.input) {
		return "", {.Output_Unnamable, strings.clone(options.input, allocator)}
	}
	return path, {}
}

// source_at guards the sources: -out: is taken as written, and a compiler that writes over its own
// input destroys it, as gcc and rustc refuse to. The file system decides rather than the spelling,
// so another case, a `..` or a link still names the file, and an imported module counts as much as
// the entry file. The lib is embedded and has no file.
@(private = "file")
source_at :: proc(path: string, files: []source.File) -> (source_path: string, found: bool) {
	output, exists := identity_of(path)
	if !exists {
		return "", false
	}
	for file, id in files {
		if source.File_ID(id) == program.LIB {
			continue
		}
		if identity, ok := identity_of(file.path); ok && identity == output {
			return file.path, true
		}
	}
	return "", false
}

@(private = "file")
File_Identity :: struct {
	device: u64,
	inode:  u128,
}

// identity_of goes through a handle because os.stat by name will not do on Windows: it records the
// full path as spelled and no file number, and os.same_file compares that path, so `MAIN.TS` and
// `main.ts` would be two files there.
@(private = "file")
identity_of :: proc(path: string) -> (identity: File_Identity, ok: bool) {
	file, open_err := os.open(path)
	if open_err != nil {
		return {}, false
	}
	defer os.close(file)
	info, stat_err := os.fstat(file, context.temp_allocator)
	if stat_err != nil {
		return {}, false
	}
	return {device = info.device, inode = info.inode}, true
}

// names_one_file compares two paths as they were written, folded and with one kind of separator.
// It never asks the file system: both of these may name something that is not there yet.
@(private = "file")
names_one_file :: proc(left, right: string) -> bool {
	folded_left := display_of(left, context.temp_allocator)
	folded_right := display_of(right, context.temp_allocator)
	return(
		key_of(folded_left, context.temp_allocator) ==
		key_of(folded_right, context.temp_allocator) \
	)
}

// RENAME_ATTEMPTS and RENAME_PAUSE are how long the last step of a build waits out a refusal it
// should not take for an answer. On Windows a file that was just written or just run stays held
// for a moment, by the virus scanner reading it or by the image section of the process that ran
// it, and MoveFileEx answers "permission denied" until it is let go; `tsnc run` twice in a row is
// enough to meet it. A tenth of a second of retries turns that into nothing, and a refusal that
// means what it says still comes back, only later.
@(private = "file")
RENAME_ATTEMPTS :: 10
@(private = "file")
RENAME_PAUSE :: 10 * time.Millisecond

// rename_into_place is what makes a build atomic: the move replaces the file whole or leaves it
// exactly as it was.
@(private = "file")
rename_into_place :: proc(paths: Paths) -> os.Error {
	err := os.rename(paths.temporary, paths.output)
	for _ in 1 ..< RENAME_ATTEMPTS {
		if err == nil {
			break
		}
		time.sleep(RENAME_PAUSE)
		err = os.rename(paths.temporary, paths.output)
	}
	return err
}

// Paths carries the output beside the temporary names because a failure names the output: the
// other two are names the user never asked for and would only have to decipher.
@(private = "file")
Paths :: struct {
	directory: string, // the temporary directory, beside the output
	temporary: string, // the artifact inside it, before the rename
	output:    string,
}

// LINKED_NAME is what an artifact is called inside its temporary directory, whichever program it
// is, the way `go build` links everything as a.out. On macOS the linker signs an arm64 executable,
// and the signature names the file the linker wrote: while that was a name with the process id in
// it, no two builds of one program were alike. A fixed name keeps the bytes of an executable
// independent of where it goes.
@(private = "file")
LINKED_NAME :: "a.out"

// artifact_paths puts the process id into the directory name, so that two compilers writing beside
// one output cannot take each other's files.
@(private = "file")
artifact_paths :: proc(output: string, allocator: runtime.Allocator) -> Paths {
	directory := fmt.aprintf("%s.%d.tmp", output, os.get_pid(), allocator = allocator)
	temporary := strings.concatenate({directory, "/", LINKED_NAME}, allocator)
	return {directory = directory, temporary = temporary, output = output}
}

// write_dump goes through a buffered writer: the dump is a line per instruction and each line is a
// handful of small writes.
@(private = "file")
write_dump :: proc(
	paths: Paths,
	files: []source.File,
	p: ir.Program_IR,
	allocator: runtime.Allocator,
) -> Driver_Error {
	file, open_err := os.open(paths.temporary, {.Write, .Create, .Trunc})
	if open_err != nil {
		return {.Output_Unwritable, reason_text(paths.output, open_err, allocator)}
	}

	buffer: [4096]byte
	out: bufio.Writer
	bufio.writer_init_with_buf(&out, os.to_writer(file), buffer[:])
	write_err := ir.write_program(bufio.writer_to_writer(&out), files, p)
	flush_err := bufio.writer_flush(&out)

	// Closed before the rename: Windows will not move a file that is still open.
	close_err := os.close(file)
	if write_err != nil || flush_err != nil {
		return {.Output_Unwritable, strings.clone(paths.output, allocator)}
	}
	if close_err != nil {
		return {.Output_Unwritable, reason_text(paths.output, close_err, allocator)}
	}
	return {}
}

// run_codegen names the failure in the detail, because codegen explains an LLVM failure through
// context.logger and the detail is all that reaches a user who installed no logger.
@(private = "file")
run_codegen :: proc(
	p: ^ir.Program_IR,
	options: Options,
	artifact: codegen.Artifact,
	paths: Paths,
	allocator: runtime.Allocator,
) -> Driver_Error {
	// One unit in v1: codegen builds one LLVM module for the whole program and ir.finish makes
	// exactly one. The several units of v2 become several calls, one per thread.
	err := codegen.emit(
		p,
		p.units[0],
		options.target,
		options.optimization,
		artifact,
		paths.temporary,
	)
	switch err {
	case .None:
		return {}
	case .Write_Failed:
		// The only one of these a user can do anything about, and the path is the whole of it.
		return {.Output_Unwritable, strings.clone(paths.output, allocator)}
	case .Unsupported_Target, .Invalid_Module, .Passes_Failed:
	}
	return {.Codegen_Failed, fmt.aprintf("%v", err, allocator = allocator)}
}

@(private = "file")
build_executable :: proc(
	p: ^ir.Program_IR,
	options: Options,
	paths: Paths,
	allocator: runtime.Allocator,
) -> Driver_Error {
	// The object lives beside the program in its temporary directory, and is removed with it.
	object := strings.concatenate({paths.temporary, OBJECT_SUFFIX}, allocator)
	object_paths := paths
	object_paths.temporary = object
	if err := run_codegen(p, options, .Object, object_paths, allocator); err.kind != .None {
		return err
	}
	// An empty runtime object path means the object of the target next to tsnc itself, which is
	// where the command in docs/development.md puts it.
	err := link.link({object}, options.target, paths.temporary, "", options.sanitize, allocator)
	if err.kind == .None {
		return {}
	}
	// The missing runtime object keeps a kind of its own: it is the one link failure a user fixes
	// with a single command, and main prints that command as a hint. The ASan one is built by
	// another command.
	if err.kind == .Runtime_Object_Missing && options.sanitize == .address {
		return {.Sanitized_Runtime_Missing, err.detail}
	}
	if err.kind == .Runtime_Object_Missing {
		return {.Runtime_Object_Missing, err.detail}
	}
	return {.Link_Failed, link_failure_text(err, allocator)}
}

// link_failure_text gives each kind a sentence, because a user reading `tsnc build` has no reason
// to know the names of link's own enum.
@(private = "file")
link_failure_text :: proc(err: link.Link_Error, allocator: runtime.Allocator) -> string {
	switch err.kind {
	case .None, .Runtime_Object_Missing:
		return "" // neither reaches here: one is success, the other is a driver kind of its own
	case .Unsupported_Target:
		return strings.clone("v1 links for the host only", allocator)
	case .Windows_SDK_Missing:
		return fmt.aprintf("the Windows SDK is missing: %s", err.detail, allocator = allocator)
	case .MSVC_Missing:
		return fmt.aprintf("the MSVC libraries are missing: %s", err.detail, allocator = allocator)
	case .Linker_Missing:
		return fmt.aprintf("%s could not be run", err.detail, allocator = allocator)
	case .Linker_Failed:
		return fmt.aprintf("the linker said:\n%s", err.detail, allocator = allocator)
	}
	return ""
}

// violations_text exists because a violation is a bug in the compiler rather than a mistake in the
// program: it has no diagnostic code and no place in the sorted list, so it goes out as the detail
// of one error, a line per violation.
@(private = "file")
violations_text :: proc(
	files: []source.File,
	p: ir.Program_IR,
	violations: []ir.Violation,
	allocator: runtime.Allocator,
) -> string {
	text := strings.builder_make(allocator)
	w := strings.to_writer(&text)
	for violation in violations {
		// Nothing to do when even this cannot be written: the error kind already says what broke.
		_ = ir.write_violation(w, files, p, violation)
	}
	return strings.to_string(text)
}

// reason_text follows the shape Entry_Unreadable already uses: the path, then why. failure_text may
// answer out of a buffer the C library reuses, so the text is copied here.
@(private = "file")
reason_text :: proc(path: string, err: os.Error, allocator: runtime.Allocator) -> string {
	return strings.concatenate({path, ": ", failure_text(path, err)}, allocator)
}

// remove_directory ignores a failure: the build is already going one way or the other, and a
// temporary that could not be removed is not worth a second message.
@(private = "file")
remove_directory :: proc(path: string) {
	_ = os.remove_all(path)
}
