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

Case. Windows and macOS open `./Util.ts` for util.ts and Linux does not, so a spelling is checked
against the names in each directory the path passes through, and one that differs only in case is
an error on every OS. A program that builds on one of them then builds on all three.
*/
package driver

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import "../ast"
import "../diag"
import "../program"
import "../source"

// BOM has to go before the file becomes a source.File: editors on Windows still write one, and
// every phase after this counts bytes from the start of the text.
BOM :: "\xef\xbb\xbf"

// Failure is why a module could not be read, kept so that a module imported from several files is
// read once and still reported at each of those imports.
Failure :: struct {
	code:   diag.Code,
	detail: string,
}

Request :: struct {
	file:      source.File_ID, // the module the request is written in
	node:      ast.Node_ID, // the Import_Named, Import_Namespace or Export_Named
	specifier: string, // the text between the quotes, as the user wrote it
	span:      source.Span, // the specifier, where a diagnostic about this request stands
	type_only: bool, // `import type`: the module is never loaded for it
}

// Closure lives only inside check_only.
Closure :: struct {
	memory:      ^Build_Memory,
	arena:       runtime.Allocator, // memory.arena, where everything below is allocated
	files:       [dynamic]source.File, // indexed by File_ID; path is the display path
	absolute:    [dynamic]string, // identity path per File_ID; empty for the embedded lib
	// The requests of each file that named a module of the program, by File_ID, in source order.
	// They are the edges program draws the module graph from.
	edges:       [dynamic][dynamic]program.Import_Edge,
	by_key:      map[string]source.File_ID, // folded identity path to the file that owns it
	failed:      map[string]Failure, // identity paths that could not be read
	listings:    map[string][]string, // folded directory path to the names in it on disk
	diagnostics: [dynamic]diag.Diagnostic, // driver's own, merged with the phases' in check_only
}

// add_file takes an empty absolute for the embedded lib, which no path resolves to.
add_file :: proc(c: ^Closure, display, absolute, text: string) -> source.File_ID {
	id := source.File_ID(len(c.files))
	append(&c.files, source.make_file(display, text, c.arena))
	append(&c.absolute, absolute)
	append(&c.edges, make([dynamic]program.Import_Edge, c.arena))

	task := new(File_Task, c.memory.allocator)
	task.file = id
	task.text = text
	append(&c.memory.tasks, task)

	if absolute != "" {
		c.by_key[key_of(absolute, c.arena)] = id
	}
	return id
}

// add_entry is the one read whose failure has no place in any source text, so it comes back as a
// Driver_Error.
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

	_ = add_file(c, display_of(input, c.arena), absolute, strip_bom(string(data)))
	return {}
}

follow_requests :: proc(c: ^Closure, id: source.File_ID) {
	if c.absolute[id] == "" {
		return // the embedded lib: it imports nothing and has no directory to resolve against
	}
	tree := &c.memory.tasks[id].tree
	for node in tree.imports {
		request, ok := read_request(tree, id, node)
		if !ok {
			continue // parse recovered over the specifier and has already reported it
		}
		resolve_request(c, request)
	}
}

// read_request answers false when parse left no string literal where the specifier goes.
read_request :: proc(
	tree: ^ast.File_AST,
	file: source.File_ID,
	node: ast.Node_ID,
) -> (
	request: Request,
	ok: bool,
) {
	path: ast.Node_ID
	// Only the request's own `import type` counts. `import { type A, b }` still loads the module,
	// so its specifiers are bind's business and not the graph's.
	#partial switch variant in tree.nodes[node].variant {
	case ast.Import_Named:
		path, request.type_only = variant.path, variant.type_only
	case ast.Import_Namespace:
		path, request.type_only = variant.path, variant.type_only
	case ast.Export_Named:
		path, request.type_only = variant.path, variant.type_only
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

	request.file = file
	request.node = node
	request.specifier = literal.value
	request.span = tree.nodes[path].span
	return request, true
}

// resolve_request reports every request on its own: two imports of the same missing module are two
// mistakes in two places, and a reader fixing them wants to see both.
resolve_request :: proc(c: ^Closure, request: Request) {
	specifier := request.specifier
	if !is_relative(specifier) {
		report(c, .Bare_Specifier, request.span, specifier)
		return
	}

	name := specifier
	if !strings.has_suffix(name, ".ts") {
		name = strings.concatenate({name, ".ts"}, c.arena)
	}

	importer := c.absolute[request.file]
	absolute := resolve_against(importer, name, c.arena)
	// Before the key: on Windows and macOS the folded key would find the file this spelling missed.
	if on_disk, differs := case_on_disk(c, importer, absolute); differs {
		report(c, .Path_Case_Mismatch, request.span, specifier, on_disk)
		return
	}
	key := key_of(absolute, c.arena)
	if id, seen := c.by_key[key]; seen {
		// A diamond, a cycle or the same module twice: one File_ID, read once, but an edge of its
		// own, since the graph is drawn from requests and not from files.
		record_edge(c, request, id)
		return
	}
	if failure, did_fail := c.failed[key]; did_fail {
		report(c, failure.code, request.span, specifier, failure.detail)
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
		report(c, failure.code, request.span, specifier, failure.detail)
		return
	}
	if len(data) > source.MAX_FILE_SIZE {
		failure := Failure {
			code   = .Module_Unreadable,
			detail = "the file is larger than a compile unit can address",
		}
		c.failed[key] = failure
		report(c, failure.code, request.span, specifier, failure.detail)
		return
	}

	display := resolve_against(c.files[request.file].path, name, c.arena)
	id := add_file(c, display, absolute, strip_bom(string(data)))
	record_edge(c, request, id)
}

// case_on_disk answers the first name on disk that the path spells in another case. It checks only
// what the specifier spells past the importer's directory: that directory was checked when the
// importer was imported, or it came from the command line, which is not part of the program. A
// name missing in every case is left to the read, which reports the module as not found.
case_on_disk :: proc(c: ^Closure, importer, absolute: string) -> (on_disk: string, differs: bool) {
	start := 0
	base := display_of(os.dir(importer), c.arena)
	for {
		end := strings.index_byte(absolute[start:], '/')
		if end < 0 {
			break
		}
		base_name: string
		base_name, base = cut_first(base)
		if absolute[start:][:end] != base_name {
			break
		}
		start += end + 1
	}

	for start < len(absolute) {
		end := strings.index_byte(absolute[start:], '/')
		if end < 0 {
			end = len(absolute) - start
		}
		name := absolute[start:][:end]
		names := listing(c, absolute[:start])
		if !slice.contains(names, name) {
			// The smallest match, because a directory on a case-sensitive file system may hold
			// several and the order it lists them in is its own.
			for entry in names {
				if strings.equal_fold(entry, name) && (on_disk == "" || entry < on_disk) {
					on_disk = entry
				}
			}
			return on_disk, on_disk != ""
		}
		start += end + 1
	}
	return "", false
}

// cut_first splits a slashed path after its first name: "/p/q" gives "" and "p/q".
cut_first :: proc(path: string) -> (first, rest: string) {
	slash := strings.index_byte(path, '/')
	if slash < 0 {
		return path, ""
	}
	return path[:slash], path[slash + 1:]
}

// listing reads a directory once per build. One that cannot be read lists nothing, and the read of
// the module says why.
listing :: proc(c: ^Closure, directory: string) -> []string {
	key := key_of(directory, c.arena)
	if names, seen := c.listings[key]; seen {
		return names
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	entries, _ := os.read_all_directory_by_path(directory, context.temp_allocator)
	names := make([]string, len(entries), c.arena)
	for entry, i in entries {
		names[i] = strings.clone(entry.name, c.arena)
	}
	c.listings[key] = names
	return names
}

// record_edge is never called for a request that resolved to nothing: a file that is not in the
// program is not a node of its graph, and driver has already reported why it is missing.
record_edge :: proc(c: ^Closure, request: Request, module: source.File_ID) {
	append(
		&c.edges[request.file],
		program.Import_Edge {
			request = request.node,
			span = request.span,
			module = module,
			type_only = request.type_only,
		},
	)
}

// report drops arguments past diag.MAX_ARGS: they cannot appear in a registry text, so there is
// nowhere to put them.
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

// failure_text gives a directory an answer of its own, because each OS reports it under a different
// name. The text may sit in a buffer the C library reuses, so a caller that keeps it copies it.
failure_text :: proc(path: string, err: os.Error) -> string {
	if os.is_dir(path) {
		return "it is a directory"
	}
	return os.error_string(err)
}

// is_relative covers all that tsnc resolves. Everything else, a package name, an absolute path or
// a URL, is out of scope for good.
is_relative :: proc(specifier: string) -> bool {
	return strings.has_prefix(specifier, "./") || strings.has_prefix(specifier, "../")
}

// resolve_against never asks the file system, so it works for a file that is not there.
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

strip_bom :: proc(text: string) -> string {
	return strings.trim_prefix(text, BOM)
}
