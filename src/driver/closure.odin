#+private
/*
The import closure: from one entry file to every file the program is made of.

Two paths per file, because they answer two different questions. The identity path is absolute and
folded to one spelling, and it only ever serves as a map key, so that a file reached as `./a` from
one module and as `../dir/a.ts` from another gets one File_ID. The display path is what a
diagnostic prints, built from the spelling the user gave the entry file, so an error in a file
imported from `src/main.ts` reads `src/lib/util.ts` and not the machine's full path.

Resolution is deliberately small, because requirements 7 and 12 keep it that way: a specifier is
relative or it is an error. There is no node_modules lookup, no index.ts, no tsconfig paths and no
extension list. `./m` and `./m.ts` both name `m.ts`, which is the one spelling Node runs and the
one tsc accepts without a flag.
*/
package driver

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

import "../ast"
import "../diag"
import "../source"

// BOM is a UTF-8 byte order mark. Editors on Windows still write one, and every phase after this
// counts bytes from the start of the text, so it has to go before the file becomes a source.File.
BOM :: "\xef\xbb\xbf"

// Failure is why a module could not be read, kept so that a module imported from several files is
// read once and still reported at each of those imports.
Failure :: struct {
	code:   diag.Code,
	detail: string,
}

// Closure is the state of one import walk. It lives only inside check_only.
Closure :: struct {
	memory:      ^Build_Memory,
	arena:       runtime.Allocator, // memory.arena, where everything below is allocated
	files:       [dynamic]source.File, // indexed by File_ID; path is the display path
	absolute:    [dynamic]string, // identity path per File_ID; empty for the embedded lib
	by_key:      map[string]source.File_ID, // folded identity path to the file that owns it
	failed:      map[string]Failure, // identity paths that could not be read
	diagnostics: [dynamic]diag.Diagnostic, // driver's own, merged with the phases' in check_only
}

// add_file gives text the next File_ID and queues its parse and bind task. absolute is empty for
// the embedded lib, which no path resolves to.
add_file :: proc(c: ^Closure, display, absolute, text: string) {
	id := source.File_ID(len(c.files))
	append(&c.files, source.make_file(display, text, c.arena))
	append(&c.absolute, absolute)

	// new, not append of a value: the task's arena allocator captures the task by pointer, and a
	// dynamic array of tasks would move them as it grows.
	task := new(File_Task, c.memory.allocator)
	task.file = id
	task.text = text
	append(&c.memory.tasks, task)

	if absolute != "" {
		c.by_key[key_of(absolute, c.arena)] = id
	}
}

// add_entry reads the file the command line named and makes it File_ID 1. It is the one read whose
// failure has no place in any source text, so it comes back as a Driver_Error.
add_entry :: proc(c: ^Closure, input: string) -> Driver_Error {
	data, read_err := os.read_entire_file(input, c.arena)
	if read_err != nil {
		detail := fmt.aprintf("%s: %s", input, failure_text(input, read_err), allocator = c.arena)
		return {kind = .Entry_Unreadable, detail = detail}
	}
	if len(data) > source.MAX_FILE_SIZE {
		return {kind = .Entry_Too_Large, detail = strings.clone(input, c.arena)}
	}

	// The file exists, so get_absolute_path resolves it on every OS. On Linux and macOS it only
	// resolves a path that does exist, which is why imports below are joined by hand instead.
	absolute, absolute_err := os.get_absolute_path(input, c.arena)
	if absolute_err != nil {
		detail := fmt.aprintf("%s: %s", input, os.error_string(absolute_err), allocator = c.arena)
		return {kind = .Entry_Unreadable, detail = detail}
	}

	add_file(c, display_of(input, c.arena), absolute, strip_bom(string(data)))
	return {}
}

// follow_requests resolves every import and re-export of one file, in source order.
follow_requests :: proc(c: ^Closure, id: source.File_ID) {
	importer := c.absolute[id]
	if importer == "" {
		return // the embedded lib: it imports nothing and has no directory to resolve against
	}
	display := c.files[id].path
	tree := &c.memory.tasks[id].tree
	for request in tree.imports {
		specifier, span, ok := request_path(tree, request)
		if !ok {
			continue // parse recovered over the specifier and has already reported it
		}
		resolve_request(c, specifier, span, importer, display)
	}
}

// request_path is the module specifier of one request and the span to report against. ok is false
// when parse left no string literal there.
request_path :: proc(
	tree: ^ast.File_AST,
	request: ast.Node_ID,
) -> (
	specifier: string,
	span: source.Span,
	ok: bool,
) {
	path: ast.Node_ID
	#partial switch variant in tree.nodes[request].variant {
	case ast.Import_Named:
		path = variant.path
	case ast.Import_Namespace:
		path = variant.path
	case ast.Export_Named:
		path = variant.path
	case:
		return
	}
	if path == ast.NO_NODE {
		return
	}
	literal, is_literal := tree.nodes[path].variant.(ast.String_Literal)
	if !is_literal {
		return
	}
	return literal.value, tree.nodes[path].span, true
}

// resolve_request turns one specifier into a file, or into the diagnostic that says why it is not
// one. Every request is reported on its own: two imports of the same missing module are two
// mistakes in two places, and a reader fixing them wants to see both.
resolve_request :: proc(
	c: ^Closure,
	specifier: string,
	span: source.Span,
	importer, display: string,
) {
	if !is_relative(specifier) {
		report(c, .Bare_Specifier, span, specifier)
		return
	}

	name := specifier
	if !strings.has_suffix(name, ".ts") {
		name = strings.concatenate({name, ".ts"}, c.arena)
	}

	absolute := resolve_against(importer, name, c.arena)
	key := key_of(absolute, c.arena)
	if _, seen := c.by_key[key]; seen {
		return // a diamond, a cycle or the same module twice: one File_ID, read once
	}
	if failure, did_fail := c.failed[key]; did_fail {
		report(c, failure.code, span, specifier, failure.detail)
		return
	}

	data, read_err := os.read_entire_file(absolute, c.arena)
	if read_err != nil {
		failure := Failure {
			code   = .Module_Not_Found,
			detail = "",
		}
		if os.exists(absolute) {
			failure.code = .Module_Unreadable
			failure.detail = strings.clone(failure_text(absolute, read_err), c.arena)
		}
		c.failed[key] = failure
		report(c, failure.code, span, specifier, failure.detail)
		return
	}
	if len(data) > source.MAX_FILE_SIZE {
		failure := Failure {
			code   = .Module_Unreadable,
			detail = "the file is larger than a compile unit can address",
		}
		c.failed[key] = failure
		report(c, failure.code, span, specifier, failure.detail)
		return
	}

	add_file(c, resolve_against(display, name, c.arena), absolute, strip_bom(string(data)))
}

// report records one of driver's own diagnostics. Arguments past diag.MAX_ARGS cannot appear in a
// registry text, so there is nowhere to put them.
report :: proc(c: ^Closure, code: diag.Code, span: source.Span, args: ..string) {
	d := diag.Diagnostic {
		code = code,
		span = span,
	}
	for arg, i in args {
		if i >= diag.MAX_ARGS {
			break
		}
		d.args[i] = arg
	}
	append(&c.diagnostics, d)
}

// failure_text says why a file could not be read, in words a user can act on. A directory gets an
// answer of its own, because each OS reports it under a different name. The text may sit in a
// buffer the C library reuses, so a caller that keeps it copies it.
failure_text :: proc(path: string, err: os.Error) -> string {
	if os.is_dir(path) {
		return "it is a directory"
	}
	return os.error_string(err)
}

// is_relative says whether a specifier is one tsnc resolves at all. Everything else, a package
// name, an absolute path or a URL, is out of scope for good.
is_relative :: proc(specifier: string) -> bool {
	return strings.has_prefix(specifier, "./") || strings.has_prefix(specifier, "../")
}

// resolve_against joins name to the directory of base and folds away `.` and `..`. It never asks
// the file system, so it works for a file that is not there.
resolve_against :: proc(base, name: string, allocator: runtime.Allocator) -> string {
	joined, join_err := os.join_path({os.dir(base), name}, allocator)
	if join_err != nil {
		return name
	}
	return display_of(joined, allocator)
}

// display_of is the spelling a path is printed and stored under: folded, with forward slashes on
// every OS, so that a diagnostic reads the same on Windows as it does in CI on Linux.
display_of :: proc(path: string, allocator: runtime.Allocator) -> string {
	cleaned, clean_err := os.clean_path(path, allocator)
	if clean_err != nil {
		return path
	}
	slashed, replace_err := os.replace_path_separators(cleaned, '/', allocator)
	if replace_err != nil {
		return cleaned
	}
	return slashed
}

// key_of is the identity of a file: one string for every spelling that names it. Windows and macOS
// compare file names without case, so two spellings that differ only in case are one file there.
key_of :: proc(absolute: string, allocator: runtime.Allocator) -> string {
	slashed := display_of(absolute, allocator)
	when ODIN_OS == .Windows || ODIN_OS == .Darwin {
		return strings.to_lower(slashed, allocator)
	} else {
		return slashed
	}
}

// strip_bom drops a UTF-8 byte order mark, so that offset 0 is the first real character.
strip_bom :: proc(text: string) -> string {
	return strings.trim_prefix(text, BOM)
}
