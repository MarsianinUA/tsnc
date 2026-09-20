/*
The types of a program: what every expression is, what every name refers to, and every mistake the
type rules catch. program freezes the files, their trees and their names; check reads that and
returns a Check_Result, which lower reads and never changes.

Partitions: one call types the files of one partition and returns a Typed_File for each. It reads
any file of the program, though, because a name used in its partition may be declared anywhere, so
the answer for a file does not depend on how the program was split. In v1 driver passes one
partition holding every file; T6.2 runs several calls at once.

Tables: the three tables of a Typed_File are as long as the file's tree.nodes and hold a fact of a
node by its ast.Node_ID. An expression holds its type, and ERROR where the rules failed. A read of a
place holds the type it has at that point rather than the one it was declared with, which is the
narrowing lower turns into a tag check. An ast.Ident holds the symbol it names, which is bind's
answer when the file declares the name, check's own when the name comes from the lib module, and the
declaration behind the import when the name was imported; an ast.Type_Ref holds the same for a type
name, and an ast.Member holds it as well where a module stands before the dot. A call holds the
signature it settled on, once the overload was picked and the type variables worked out.

Order: a declaration is typed once, the first time anything asks for it, and the answer is cached by
symbol. The walk over the statements asks for the same thing, so a name used above its declaration
and a name never used at all both get the same work done exactly once. That is also why the body of
a function is read where its type is worked out, and not where the walk reaches it.

Types: every type is interned in the table of this call, so a Type_ID is meaningful only together
with Check_Result.types. See types.odin.

What this package types: primitives, literal types, unions, functions and arrows; objects under the
exact-type rule of requirements 3.3, arrays, `interface` and `type`, contextual typing, and the
generic signatures of the built-in types, which is the whole of src/lib/lib.d.ts; unions narrowed
through bind's flow graph, and the rules of requirements 3.8 for `as` and `!`; names another module
declares, through the import and export tables, which is modules.odin; and the rules of the subset
that need a type or a file to decide, which is subset.odin. Constructs the compiler can reject on
sight are rejected in parse with a T2xxx code and never reach here.

Memory: the type table, the node tables, the Typed_File list and the diagnostics come from the
allocator passed in, which is meant to be an arena; check never frees. Names and texts are borrowed
from the trees, so the result must not outlive the program. Scratch data, including the caches only
one call needs and the node tables of a file the call reads without typing, goes to
context.temp_allocator.
*/
package check

import "base:runtime"

import "../ast"
import "../bind"
import "../diag"
import "../program"
import "../source"

// Symbol_Ref names a symbol in any file of the program. bind resolves a name inside its own file and
// leaves NO_SYMBOL on the rest; check finishes the job for the names of the lib module, and follows
// an import to the declaration behind it. A zero Symbol_Ref is the lib file and NO_SYMBOL: it means
// nothing.
Symbol_Ref :: struct {
	file:   source.File_ID,
	symbol: bind.Symbol_ID,
}

// Typed_File is what check learned about one file.
Typed_File :: struct {
	file:            source.File_ID,
	node_types:      []Type_ID, // as long as tree.nodes; ERROR where a node has no type of its own
	node_symbols:    []Symbol_Ref, // as long as tree.nodes; what an ast.Ident names
	// As long as tree.nodes. For an ast.Call it is the signature the call settled on, after the
	// overload was picked and any type variable worked out; ERROR on every other node. lower reads
	// the answer instead of working it out again.
	node_signatures: []Type_ID,
}

// Facts are the three tables of one file, each as long as its tree.nodes. A file of the partition
// hands them to the result as its Typed_File; a file the checker only reads to learn the type of a
// name gets a set of its own all the same, so that the work done there lands somewhere. Without it
// the answer would depend on which checker read the file first: a result inferred from a narrowed
// value needs the narrowing, and the narrowing reads these tables.
@(private)
Facts :: struct {
	node_types:      []Type_ID,
	node_symbols:    []Symbol_Ref,
	node_signatures: []Type_ID,
}

// Check_Result is the frozen answer of one call. Its Type_ID values index its own types and mean
// nothing in another call's.
Check_Result :: struct {
	partition: []source.File_ID, // the files this call typed, in the order they were given
	types:     []Type, // the type table of this call, indexed by Type_ID
	files:     []Typed_File, // one per partition entry, in the same order
}

// check types the files of partition and returns their facts together with every diagnostic it
// found. It reports every mistake it sees rather than stopping at the first, and always returns a
// whole result: a node it could not type holds the error type.
@(require_results)
check :: proc(
	prog: ^program.Program,
	partition: []source.File_ID,
	allocator := context.allocator,
) -> (
	result: Check_Result,
	diagnostics: []diag.Diagnostic,
) {
	c := Checker {
		program      = prog,
		allocator    = allocator,
		table        = make_table(allocator),
		in_partition = make([]bool, len(prog.files), context.temp_allocator),
		facts        = make([]Facts, len(prog.files), context.temp_allocator),
		symbol_types = make(map[Symbol_Ref]Type_ID, context.temp_allocator),
		resolving    = make(map[Symbol_Ref]bool, context.temp_allocator),
		bindings     = make(map[Decl_Ref]Type_ID, context.temp_allocator),
		aliases      = make(map[Decl_Ref]bool, context.temp_allocator),
		trail        = make(Trail, 0, 8, context.temp_allocator),
		narrowing    = make_narrowing(context.temp_allocator),
		diagnostics  = make([dynamic]diag.Diagnostic, allocator),
	}
	defer free_scratch(&c)
	for file in partition {
		c.in_partition[file] = true
	}

	files := make([]Typed_File, len(partition), allocator)
	for file, i in partition {
		files[i] = check_file(&c, file)
	}
	return freeze(&c, partition, files), c.diagnostics[:]
}

// typed_file is the facts of one file, when that file belongs to this result.
typed_file :: proc(result: Check_Result, file: source.File_ID) -> (^Typed_File, bool) {
	for &typed in result.files {
		if typed.file == file {
			return &typed, true
		}
	}
	return nil, false
}

// Checker is the state of one check call.
@(private)
Checker :: struct {
	program:      ^program.Program,
	allocator:    runtime.Allocator,
	table:        Table,
	// Whether a file is one of this call's, by source.File_ID, so that report is one index.
	in_partition: []bool,
	// The fact tables of every file, by source.File_ID, built the first time the checker reads the
	// file. See Facts.
	facts:        []Facts,
	// The type of a symbol of any file, worked out the first time anything asks for it. The cache
	// belongs to this call alone, as the type table does: a Type_ID of one checker means nothing
	// in another.
	symbol_types: map[Symbol_Ref]Type_ID,
	// The symbols whose type is being worked out right now. A declaration that needs its own type
	// finds itself here, which is the only way that search could fail to end.
	resolving:    map[Symbol_Ref]bool,
	// The type arguments in force while the members of a generic lib declaration are read: `T` of
	// `Array<T>` stands for `number` while `Array<number>` is built. Saved and restored around one
	// instantiation, so a nested one cannot see the outer bindings.
	bindings:     map[Decl_Ref]Type_ID,
	// The type aliases being resolved right now. An alias is transparent, so one that names itself
	// has nothing to stand for; an interface needs no guard, because its row is reserved first.
	aliases:      map[Decl_Ref]bool,
	// The lib declarations check has to know by name rather than by use. Filled on first use.
	lib:          Lib_Types,
	// The buffer fits compares object types in. See Trail.
	trail:        Trail,
	// The buffer narrow_reference walks the flow graph in. See Narrowing.
	narrowing:    Narrowing,
	diagnostics:  [dynamic]diag.Diagnostic,
	at:           Place,
}

// Place is where the checker is reading: one file, and the function inside it whose body it is in.
// A symbol declared in another file moves the checker there and back.
@(private)
Place :: struct {
	file:            source.File_ID,
	tree:            ^ast.File_AST,
	bound:           ^bind.Bound_File,
	// The fact tables of that file, which are Checker.facts of it. They are nil only while a
	// generic lib declaration is being instantiated, where drop_facts_of_instance clears them so
	// that the instance does not overwrite what the declaration itself recorded.
	node_types:      []Type_ID,
	node_symbols:    []Symbol_Ref,
	node_signatures: []Type_ID,
	// The declared result of the function being typed. While a result is being inferred instead,
	// returns collects what its `return` statements gave and result says nothing.
	result:          Type_ID,
	returns:         ^[dynamic]Type_ID,
}

// check_file types one file of the partition from its root down. A declaration of the file that an
// earlier file already asked for is typed once: its facts are in the file's tables already, and the
// walk over the statements finds the answer in the symbol cache.
@(private)
check_file :: proc(c: ^Checker, file: source.File_ID) -> Typed_File {
	previous := move_to(c, file)
	defer c.at = previous

	module, is_module := c.at.tree.nodes[ast.ROOT].variant.(ast.Module)
	ensure(is_module, "the root of a File_AST is its Module")
	check_statements(c, module.statements)

	facts := c.facts[file]
	return {
		file = file,
		node_types = facts.node_types,
		node_symbols = facts.node_symbols,
		node_signatures = facts.node_signatures,
	}
}

// move_to points the checker at a file and answers with the place to move back to. It is how the
// type of a symbol declared elsewhere gets worked out.
@(private)
move_to :: proc(c: ^Checker, file: source.File_ID) -> (previous: Place) {
	facts := facts_of(c, file)
	previous = c.at
	c.at = Place {
		file            = file,
		tree            = &c.program.trees[file],
		bound           = &c.program.bound[file],
		node_types      = facts.node_types,
		node_symbols    = facts.node_symbols,
		node_signatures = facts.node_signatures,
		result          = ERROR,
	}
	return previous
}

// facts_of is the fact tables of one file, built the first time the checker reads it. A file of the
// partition takes them from the checker's allocator, because they become its Typed_File; a file the
// checker only reads takes scratch, which free_scratch gives back.
@(private)
facts_of :: proc(c: ^Checker, file: source.File_ID) -> Facts {
	if c.facts[file].node_types != nil {
		return c.facts[file]
	}

	count := len(c.program.trees[file].nodes)
	allocator := c.allocator if c.in_partition[file] else context.temp_allocator
	c.facts[file] = {
		node_types      = make([]Type_ID, count, allocator),
		node_symbols    = make([]Symbol_Ref, count, allocator),
		node_signatures = make([]Type_ID, count, allocator),
	}
	return c.facts[file]
}

// freeze turns the checker's growing tables into the slices of the result.
@(private)
freeze :: proc(c: ^Checker, partition: []source.File_ID, files: []Typed_File) -> Check_Result {
	owned := make([]source.File_ID, len(partition), c.allocator)
	copy(owned, partition)
	return {partition = owned, types = c.table.types[:], files = files}
}

// free_scratch gives back what only the check needed. The temporary allocator of an arena keeps its
// pages until its owner resets them, so this returns memory only to an allocator that frees, such
// as the tracking allocator of the tests.
@(private)
free_scratch :: proc(c: ^Checker) {
	// A slice remembers no allocator, so every one has to be named: delete would otherwise hand
	// scratch memory to the allocator of the context, which never owned it. in_partition goes last,
	// because the tables to give back are the ones it says are not ours.
	for facts, file in c.facts {
		if c.in_partition[file] {
			continue // the file's tables are its Typed_File and belong to the result
		}
		delete(facts.node_types, context.temp_allocator)
		delete(facts.node_symbols, context.temp_allocator)
		delete(facts.node_signatures, context.temp_allocator)
	}
	delete(c.facts, context.temp_allocator)
	delete(c.in_partition, context.temp_allocator)
	delete(c.symbol_types)
	delete(c.resolving)
	delete(c.bindings)
	delete(c.aliases)
	delete(c.trail)
	delete(c.narrowing.answers)
	delete(c.narrowing.loops)
	delete(c.table.key.buf)
}

// Facts of a node.

// set_type records the type of a node and hands it back, so a caller can end on it. A file outside
// this partition has no tables and drops the fact.
@(private)
set_type :: proc(c: ^Checker, id: ast.Node_ID, type: Type_ID) -> Type_ID {
	if c.at.node_types != nil {
		c.at.node_types[id] = type
	}
	return type
}

// set_symbol records what a name refers to.
@(private)
set_symbol :: proc(c: ^Checker, id: ast.Node_ID, ref: Symbol_Ref) {
	if c.at.node_symbols != nil {
		c.at.node_symbols[id] = ref
	}
}

// set_signature records the signature a call settled on.
@(private)
set_signature :: proc(c: ^Checker, id: ast.Node_ID, signature: Type_ID) {
	if c.at.node_signatures != nil {
		c.at.node_signatures[id] = signature
	}
}

// Diagnostics.

// report records a diagnostic at span. Arguments past diag.MAX_ARGS are dropped: a text that needs
// more than the registry holds is a text to rewrite.
//
// A diagnostic about a file outside this partition is dropped. A checker reads such a file to learn
// the type of a name used in its own, and would otherwise report what it finds there, which the
// checker that owns the file reports as well. Since every file belongs to exactly one partition,
// dropping it here is what makes one partition and any other split give the same diagnostics.
@(private)
report :: proc(c: ^Checker, code: diag.Code, span: source.Span, args: ..string) {
	if !c.in_partition[span.file] {
		return
	}

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

// report_types records a diagnostic whose two arguments are types, which is most of them.
@(private)
report_types :: proc(c: ^Checker, code: diag.Code, span: source.Span, a, b: Type_ID) {
	report(c, code, span, text_of(c, a), text_of(c, b))
}

// text_of is how a type reads in a message. It comes from the checker's allocator, because a
// diagnostic borrows its arguments and outlives any scratch.
@(private)
text_of :: proc(c: ^Checker, id: Type_ID) -> string {
	return type_text(c.table.types[:], id, c.allocator)
}

// span_of is where a diagnostic about a node stands.
@(private)
span_of :: proc(c: ^Checker, id: ast.Node_ID) -> source.Span {
	return c.at.tree.nodes[id].span
}

// fits reports whether a value of source may stand where target is expected. One trail serves the
// whole check: assignable reads the frozen rows and never calls back here, so no second comparison
// can be running while this one is.
@(private)
fits :: proc(c: ^Checker, source, target: Type_ID) -> bool {
	clear(&c.trail)
	return assignable(c.table.types[:], source, target, &c.trail)
}

// comparable reports whether two types have a value in common, which is what `===` and a `switch`
// case ask: a comparison of two types that can never be equal is a mistake rather than a test, and
// it is also the question narrowing asks of each member of a union.
//
// The error type and `any` fit in both directions and everything fits `unknown`, so a value the
// rules have already given up on never produces a second message here.
@(private)
comparable :: proc(c: ^Checker, a, b: Type_ID) -> bool {
	return fits(c, a, b) || fits(c, b, a)
}

// union_of is the canonical union of two types, which is what a ternary, a logical operator and an
// optional parameter all come down to.
@(private)
union_of :: proc(c: ^Checker, a, b: Type_ID) -> Type_ID {
	pair := [2]Type_ID{a, b}
	return union_type(&c.table, pair[:])
}
