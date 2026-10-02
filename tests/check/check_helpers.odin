package check_tests

import "core:fmt"
import "core:strings"
import "core:testing"

import "../../src/ast"
import "../../src/bind"
import "../../src/check"
import "../../src/diag"
import "../../src/parse"
import "../../src/program"
import "../../src/source"

// LIB_TEXT is the real lib.d.ts rather than a stub: a stub would drift away from the file the
// compiler ships, and one of the things these tests have to prove is that the real one types
// without a single diagnostic.
//
// Nothing here goes through driver: driver owns Options, which names an optimization level, so it
// links codegen and llvm, and these tests would then need LLVM-C.dll on PATH to run at all.
LIB_TEXT :: #load("../../src/lib/lib.d.ts", string)

// LIB mirrors program.LIB: the lib module is File_ID zero of every program.
LIB :: source.File_ID(0)

// MAIN is the File_ID of the first source a test passes, the one it usually asks about.
MAIN :: source.File_ID(1)

// Error holds the 1-based line and column where a diagnostic starts, the way a user reads them.
Error :: struct {
	code:   diag.Code,
	line:   i32,
	column: i32,
}

File_Error :: struct {
	file:   source.File_ID,
	code:   diag.Code,
	line:   i32,
	column: i32,
}

Checked :: struct {
	program:     program.Program,
	result:      check.Check_Result,
	errors:      []Error, // check's own, in print order
	file_errors: []File_Error, // the same, one for one
}

// check_sources makes the lib file module zero and each source the next File_ID, named `m1.ts`,
// `m2.ts` and on unless names says otherwise. A source names another by its path from its own
// directory, `"./m2.ts"` or `"./m2"`, and make_edges resolves both spellings the way driver does.
// Everything lives in the temp allocator, which the test runner frees before each test, so a test
// frees nothing.
check_sources :: proc(
	t: ^testing.T,
	sources: []string,
	partition: []source.File_ID,
	names: []string = nil,
	loc := #caller_location,
) -> Checked {
	texts := make([]string, len(sources) + 1, context.temp_allocator)
	texts[0] = LIB_TEXT
	copy(texts[1:], sources)

	count := len(texts)
	files := make([]source.File, count, context.temp_allocator)
	trees := make([]ast.File_AST, count, context.temp_allocator)
	bound := make([]bind.Bound_File, count, context.temp_allocator)
	imports := make([][]program.Import_Edge, count, context.temp_allocator)

	paths := make([]string, count, context.temp_allocator)
	paths[0] = "lib.d.ts"
	for i in 1 ..< count {
		paths[i] = names[i - 1] if names != nil else fmt.tprintf("m%d.ts", i)
	}

	for text, i in texts {
		path := paths[i]
		files[i] = source.make_file(path, text, context.temp_allocator)

		tree, parse_diagnostics := parse.parse_file(
			text,
			source.File_ID(i),
			context.temp_allocator,
		)
		trees[i] = tree
		bound[i], _ = bind.bind_file(&trees[i], context.temp_allocator)
		imports[i] = make_edges(&trees[i], path, paths)

		// A test says what check does, so anything the layers under it report is a broken test.
		testing.expectf(
			t,
			len(parse_diagnostics) == 0,
			"%s: parse %v",
			path,
			errors_of(files, parse_diagnostics),
			loc = loc,
		)
	}

	prog, graph_diagnostics := program.build(files, trees, bound, imports, context.temp_allocator)
	testing.expectf(t, len(graph_diagnostics) == 0, "program %v", graph_diagnostics, loc = loc)

	result, diagnostics := check.check(&prog, partition, context.temp_allocator)
	diag.sort(diagnostics)

	checked := Checked {
		program     = prog,
		result      = result,
		errors      = errors_of(files, diagnostics),
		file_errors = file_errors_of(files, diagnostics),
	}
	check_typed(t, checked, loc)
	return checked
}

// every_source is the partition of a whole program: every file but the lib, which is module zero
// and is read rather than typed, as driver's partitions leave it.
every_source :: proc(count: int) -> []source.File_ID {
	partition := make([]source.File_ID, count, context.temp_allocator)
	for i in 0 ..< count {
		partition[i] = source.File_ID(i + 1)
	}
	return partition
}

// make_edges is the module graph of one file: an edge for every import or re-export whose specifier
// names another source of the test. driver resolves a path on disk, where `"./m"` and `"./m.ts"` both
// name `m.ts`; here the file names are known, so the same two spellings are matched against them. A
// specifier that names nothing gets no edge, which is what driver leaves behind after reporting it.
@(private = "file")
make_edges :: proc(
	tree: ^ast.File_AST,
	importer: string,
	paths: []string,
) -> []program.Import_Edge {
	edges := make([dynamic]program.Import_Edge, 0, len(tree.imports), context.temp_allocator)
	for request in tree.imports {
		path, type_only := request_path(tree, request)
		if path == ast.NO_NODE {
			continue
		}
		literal, is_literal := tree.nodes[path].variant.(ast.String_Literal)
		if !is_literal {
			continue
		}
		module, found := module_named(importer, literal.value, paths)
		if !found {
			continue
		}
		append(
			&edges,
			program.Import_Edge {
				request = request,
				span = tree.nodes[path].span,
				module = module,
				type_only = type_only,
			},
		)
	}
	return edges[:]
}

@(private = "file")
request_path :: proc(
	tree: ^ast.File_AST,
	request: ast.Node_ID,
) -> (
	path: ast.Node_ID,
	type_only: bool,
) {
	#partial switch v in tree.nodes[request].variant {
	case ast.Import_Named:
		return v.path, v.type_only
	case ast.Import_Namespace:
		return v.path, v.type_only
	case ast.Export_Named:
		return v.path, v.type_only
	}
	return ast.NO_NODE, false
}

// module_named reads the specifier from the importer's directory, which is `""` for `m1.ts` and
// `modules/` for `modules/counter.ts`.
@(private = "file")
module_named :: proc(
	importer, specifier: string,
	paths: []string,
) -> (
	module: source.File_ID,
	found: bool,
) {
	directory := importer[:strings.last_index_byte(importer, '/') + 1]
	name := strings.concatenate(
		{directory, strings.trim_prefix(specifier, "./")},
		context.temp_allocator,
	)
	for path, i in paths {
		if path == name || path == strings.concatenate({name, ".ts"}, context.temp_allocator) {
			return source.File_ID(i), true
		}
	}
	return 0, false
}

// check_text keeps the lib outside the partition, which is what a checker over a partition of a
// real program sees.
check_text :: proc(t: ^testing.T, text: string, loc := #caller_location) -> Checked {
	one := [1]string{text}
	partition := [1]source.File_ID{MAIN}
	return check_sources(t, one[:], partition[:], loc = loc)
}

expect_checked :: proc(t: ^testing.T, text: string, loc := #caller_location) -> Checked {
	c := check_text(t, text, loc)
	testing.expectf(t, len(c.errors) == 0, "%q: %v", text, c.errors, loc = loc)
	return c
}

// declared_text is the type check gave the declaration of that name, printed. It is what a test
// about inference asks for.
//
// A name holds one value and one type, and the lib file uses both of `String` and `Math`, so this
// reads the value.
declared_text :: proc(c: Checked, name: string, file := MAIN) -> string {
	typed, ok := check.typed_file(c.result, file)
	if !ok {
		return "<not in the partition>"
	}
	for symbol in c.program.bound[file].symbols[1:] {
		is_value := .Value in bind.meanings(symbol.kind)
		if is_value && symbol.name.text == name && symbol.declaration != ast.NO_NODE {
			return type_text(c, typed.node_types[symbol.declaration])
		}
	}
	return "<no such name>"
}

// use_text is the type of one use of a name: the occurrence-th ast.Ident with that text, counted
// from the start of the file.
use_text :: proc(c: Checked, name: string, occurrence := 0, file := MAIN) -> string {
	typed, ok := check.typed_file(c.result, file)
	if !ok {
		return "<not in the partition>"
	}
	seen := 0
	for node, id in c.program.trees[file].nodes {
		identifier, is_ident := node.variant.(ast.Ident)
		if !is_ident || identifier.name != name {
			continue
		}
		if seen == occurrence {
			return type_text(c, typed.node_types[id])
		}
		seen += 1
	}
	return "<no such use>"
}

// call_text is the signature the occurrence-th call of the file settled on, printed. It is what a
// test about an overload or a generic signature asks for.
call_text :: proc(c: Checked, occurrence := 0, file := MAIN) -> string {
	typed, ok := check.typed_file(c.result, file)
	if !ok {
		return "<not in the partition>"
	}
	seen := 0
	for node, id in c.program.trees[file].nodes {
		if _, is_call := node.variant.(ast.Call); !is_call {
			continue
		}
		if seen == occurrence {
			return type_text(c, typed.node_signatures[id])
		}
		seen += 1
	}
	return "<no such call>"
}

type_text :: proc(c: Checked, id: check.Type_ID) -> string {
	return check.type_text(c.result.types, id, context.temp_allocator)
}

// check_typed asserts what every Check_Result has to hold, whatever program it came from. Every
// test runs it, the way the bind suite runs check_bound.
check_typed :: proc(t: ^testing.T, c: Checked, loc := #caller_location) {
	testing.expectf(
		t,
		len(c.result.types) >= len(check.Basic_Kind),
		"the table has %d rows, too few for the types with no parts",
		len(c.result.types),
		loc = loc,
	)

	for typed in c.result.files {
		nodes := len(c.program.trees[typed.file].nodes)
		lengths := len(typed.node_types) == nodes && len(typed.node_symbols) == nodes
		testing.expectf(
			t,
			lengths && len(typed.node_signatures) == nodes,
			"file %d: tables are %d, %d and %d long, want %d",
			typed.file,
			len(typed.node_types),
			len(typed.node_symbols),
			len(typed.node_signatures),
			nodes,
			loc = loc,
		)
		for type in typed.node_types {
			testing.expectf(
				t,
				int(type) < len(c.result.types),
				"a node holds type %d, past the end of the table",
				type,
				loc = loc,
			)
		}
		for signature, id in typed.node_signatures {
			if signature == check.ERROR {
				continue
			}
			_, is_call := c.program.trees[typed.file].nodes[id].variant.(ast.Call)
			testing.expectf(t, is_call, "a node that is no call settled on a signature", loc = loc)
			_, is_function := c.result.types[signature].(check.Function)
			testing.expectf(
				t,
				is_function,
				"a call settled on %s, which is no signature",
				type_text(c, signature),
				loc = loc,
			)
		}
		for ref in typed.node_symbols {
			known :=
				int(ref.file) < len(c.program.files) &&
				int(ref.symbol) < len(c.program.bound[ref.file].symbols)
			testing.expectf(t, known, "a node names %v, which is not a symbol", ref, loc = loc)
		}
	}

	for widening, i in c.result.widenings {
		_, source_is_object := c.result.types[widening.source].(check.Object)
		_, target_is_object := c.result.types[widening.target].(check.Object)
		_, source_is_function := c.result.types[widening.source].(check.Function)
		_, target_is_function := c.result.types[widening.target].(check.Function)
		two_objects := source_is_object && target_is_object
		two_functions := source_is_function && target_is_function
		testing.expectf(
			t,
			(two_objects || two_functions) && widening.source != widening.target,
			"a widening of %s into %s, which are not two object or two function types",
			type_text(c, widening.source),
			type_text(c, widening.target),
			loc = loc,
		)
		if i == 0 {
			continue
		}
		previous := c.result.widenings[i - 1]
		ascending :=
			previous.source < widening.source ||
			previous.source == widening.source && previous.target < widening.target
		testing.expectf(
			t,
			ascending,
			"the widenings are not sorted, or one is there twice",
			loc = loc,
		)
	}

	for type in c.result.types {
		if object, is_object := type.(check.Object); is_object {
			check_object(t, c, object, loc)
		}
		if array, is_array := type.(check.Array); is_array {
			testing.expectf(
				t,
				int(array.element) < len(c.result.types),
				"an array element is past the end of the table",
				loc = loc,
			)
		}

		union_type, is_union := type.(check.Union)
		if !is_union {
			continue
		}
		testing.expectf(
			t,
			len(union_type.members) >= 2,
			"a union of %d members: one member is that member",
			len(union_type.members),
			loc = loc,
		)
		for member, i in union_type.members {
			testing.expectf(
				t,
				int(member) < len(c.result.types),
				"a union member is past the end of the table",
				loc = loc,
			)
			_, nested := c.result.types[member].(check.Union)
			testing.expectf(t, !nested, "a union holds a union", loc = loc)
			if i > 0 {
				testing.expectf(
					t,
					union_type.members[i - 1] != member,
					"a union holds one member twice",
					loc = loc,
				)
			}
		}
	}
}

// check_object asserts what lower relies on: the fields are in canonical order, by name, with no
// name twice, and every field type is a row of the table.
@(private = "file")
check_object :: proc(t: ^testing.T, c: Checked, object: check.Object, loc := #caller_location) {
	for field, i in object.fields {
		testing.expectf(
			t,
			int(field.type) < len(c.result.types),
			"field `%s` holds a type past the end of the table",
			field.name,
			loc = loc,
		)
		if i == 0 {
			continue
		}
		testing.expectf(
			t,
			object.fields[i - 1].name < field.name,
			"fields `%s` and `%s` are out of canonical order, or are one name twice",
			object.fields[i - 1].name,
			field.name,
			loc = loc,
		)
	}
}

@(private = "file")
errors_of :: proc(files: []source.File, diagnostics: []diag.Diagnostic) -> []Error {
	errors := make([]Error, len(diagnostics), context.temp_allocator)
	for d, i in diagnostics {
		position := source.position(files[d.span.file], d.span.start)
		errors[i] = {d.code, position.line, position.column}
	}
	return errors
}

@(private = "file")
file_errors_of :: proc(files: []source.File, diagnostics: []diag.Diagnostic) -> []File_Error {
	errors := make([]File_Error, len(diagnostics), context.temp_allocator)
	for d, i in diagnostics {
		position := source.position(files[d.span.file], d.span.start)
		errors[i] = {d.span.file, d.code, position.line, position.column}
	}
	return errors
}

lines :: proc(parts: ..string) -> string {
	return strings.join(parts, "\n", context.temp_allocator)
}
