/*
The types of a program, the Check_Result and Typed_File of
docs/architecture-plan-tsnc.md#check_result-and-typed_file-package-check.

Partitions: one call types the files of one partition and returns a Typed_File for each. It reads
any file of the program, though, because a name used in its partition may be declared anywhere, so
the answer for a file does not depend on how the program was split.

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
and a name never used at all both get the same work done exactly once. The body of a function whose
result is inferred is read where its type is worked out, and not where the walk reaches it; a body
or an initializer whose type is written out waits until no search is open (resolve.odin). A read
narrowed through the top level of a module first walks what stands above it there (walk_above),
so whichever declaration was typed first it reads the same facts, or none in a loop through them.

Types: every type is interned in the table of this call, so a Type_ID is meaningful only together
with Check_Result.types. See types.odin.

Constructs the compiler can reject on sight are rejected in parse with a T2xxx code and never reach
here.

Memory: names and texts are borrowed from the trees, so the result must not outlive the program. The
caches only one call needs and the node tables of a file the call reads without typing are scratch
in context.temp_allocator.
*/
package check

import "base:runtime"
import "core:slice"

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

// Check_Result holds Type_ID values that index its own types and mean nothing in another call's.
Check_Result :: struct {
	partition: []source.File_ID, // in the order they were given
	types:     []Type, // indexed by Type_ID
	files:     []Typed_File, // one per partition entry, in the same order
	// Every flow of an object, a function or an array into another type of its kind the rules
	// accepted, sorted by (source, target) with no repeats. lower gives two objects one layout, two
	// functions one signature and two arrays one element slot, so the value that flows is the same
	// value with no copy, as in Node.
	widenings: []Widening,
	// Every store through an object or an array type, sorted by (through, slot) with no repeats.
	// lower joins the layouts of what flows into a type written through; one only read through
	// keeps them.
	writes:    []Write,
}

// Widening is an object type accepted where another object type was expected, a function type where
// another function type was, or an array type where another array type was: `const b: B = a`, an
// argument, a return, a field of either, a member of a union, an element of an array, a parameter
// or the result of a function that flows.
Widening :: struct {
	source: Type_ID,
	target: Type_ID,
}

// Write is a store into a cell through the type `through`: `o.f = v`, `o.f++`, `a[i] = v`, push,
// pop and sort, and an `as` that narrows, which needs the layouts joined as a store does. slot is
// the declared type of what is stored, VOID where nothing new is (pop, sort).
Write :: struct {
	through: Type_ID,
	slot:    Type_ID,
}

// check reports every mistake it sees rather than stopping at the first, and always returns a whole
// result: a node it could not type holds the error type.
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
		walks        = make([]Module_Walk, len(prog.files), context.temp_allocator),
		symbol_types = make(map[Symbol_Ref]Type_ID, context.temp_allocator),
		search       = make_search(context.temp_allocator),
		alias_loops  = make([dynamic]Symbol_Ref, context.temp_allocator),
		deferred     = make([dynamic]Deferred, context.temp_allocator),
		bindings     = make(map[Decl_Ref]Type_ID, context.temp_allocator),
		muted        = make([dynamic]source.Span, context.temp_allocator),
		pending      = make([dynamic]Pending, context.temp_allocator),
		trail        = make(Trail, 0, 8, context.temp_allocator),
		widenings    = make([dynamic]Widening, context.temp_allocator),
		writes       = make([dynamic]Write, context.temp_allocator),
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

typed_file :: proc(result: Check_Result, file: source.File_ID) -> (^Typed_File, bool) {
	for &typed in result.files {
		if typed.file == file {
			return &typed, true
		}
	}
	return nil, false
}

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
	walks:        []Module_Walk, // by source.File_ID
	// The type of a symbol of any file, worked out the first time anything asks for it. The cache
	// belongs to this call alone, as the type table does: a Type_ID of one checker means nothing
	// in another.
	symbol_types: map[Symbol_Ref]Type_ID,
	search:       Search,
	alias_loops:  [dynamic]Symbol_Ref, // the first member of each alias loop reported
	deferred:     [dynamic]Deferred,
	// The type arguments in force while the members of a generic declaration are read: `T` of
	// `Array<T>` stands for `number` while `Array<number>` is built. Saved and restored around one
	// instantiation, so a nested one cannot see the outer bindings.
	bindings:     map[Decl_Ref]Type_ID,
	// The generic declarations being instantiated, inside whose spans report stays quiet.
	muted:        [dynamic]source.Span,
	pending:      [dynamic]Pending,
	// The lib declarations check has to know by name rather than by use. Filled on first use.
	lib:          Lib_Types,
	trail:        Trail,
	// The widenings fits found so far, in the order it found them; freeze sorts them. The list is
	// also the visited set of the walk that fills it.
	widenings:    [dynamic]Widening,
	writes:       [dynamic]Write,
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
	// generic declaration is being instantiated, where enter_instance clears them so that the
	// instance does not overwrite what the declaration itself recorded.
	node_types:      []Type_ID,
	node_symbols:    []Symbol_Ref,
	node_signatures: []Type_ID,
	// The declared result of the function being typed. While a result is being inferred instead,
	// returns collects what its `return` statements gave and result says nothing.
	result:          Type_ID,
	returns:         ^[dynamic]Type_ID,
}

// check_file types a declaration that an earlier file already asked for only once: its facts are in
// the file's tables already, and the walk over the statements finds the answer in the symbol cache.
@(private)
check_file :: proc(c: ^Checker, file: source.File_ID) -> Typed_File {
	previous := move_to(c, file)
	defer c.at = previous

	module, is_module := c.at.tree.nodes[ast.ROOT].variant.(ast.Module)
	ensure(is_module, "the root of a File_AST is its Module")
	walk_module(c, module.statements)

	facts := c.facts[file]
	return {
		file = file,
		node_types = facts.node_types,
		node_symbols = facts.node_symbols,
		node_signatures = facts.node_signatures,
	}
}

// move_to is how the type of a symbol declared elsewhere gets worked out. The caller restores the
// place it returns.
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

// facts_of gives a file of the partition tables from the checker's allocator, because they become
// its Typed_File; a file the checker only reads takes scratch, which free_scratch gives back.
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

@(private)
freeze :: proc(c: ^Checker, partition: []source.File_ID, files: []Typed_File) -> Check_Result {
	owned := make([]source.File_ID, len(partition), c.allocator)
	copy(owned, partition)
	widenings := slice.clone(c.widenings[:], c.allocator)
	slice.sort_by(widenings, proc(a, b: Widening) -> bool {
		return a.source < b.source || a.source == b.source && a.target < b.target
	})
	writes := slice.clone(c.writes[:], c.allocator)
	slice.sort_by(writes, proc(a, b: Write) -> bool {
		return a.through < b.through || a.through == b.through && a.slot < b.slot
	})
	return {
		partition = owned,
		types = c.table.types[:],
		files = files,
		widenings = widenings,
		writes = slice.unique(writes),
	}
}

// free_scratch matters only to an allocator that frees, such as the tracking allocator of the
// tests: the temporary allocator of an arena keeps its pages until its owner resets them.
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
	delete(c.walks, context.temp_allocator)
	delete(c.in_partition, context.temp_allocator)
	delete(c.symbol_types)
	delete(c.search.frames)
	delete(c.search.index)
	delete(c.alias_loops)
	delete(c.deferred)
	delete(c.bindings)
	delete(c.muted)
	delete(c.pending)
	delete(c.trail)
	delete(c.widenings)
	delete(c.writes)
	delete(c.narrowing.answers)
	delete(c.narrowing.loops)
	delete(c.narrowing.partial)
	delete(c.table.key.buf)
}

// set_type hands the type back so that a caller can end on it. See Place for the tables it skips.
@(private)
set_type :: proc(c: ^Checker, id: ast.Node_ID, type: Type_ID) -> Type_ID {
	if c.at.node_types != nil {
		c.at.node_types[id] = type
	}
	return type
}

@(private)
set_symbol :: proc(c: ^Checker, id: ast.Node_ID, ref: Symbol_Ref) {
	if c.at.node_symbols != nil {
		c.at.node_symbols[id] = ref
	}
}

@(private)
set_signature :: proc(c: ^Checker, id: ast.Node_ID, signature: Type_ID) {
	if c.at.node_signatures != nil {
		c.at.node_signatures[id] = signature
	}
}

@(private)
report :: proc(c: ^Checker, code: diag.Code, span: source.Span, args: ..string) {
	for muted in c.muted {
		if span.file == muted.file && muted.start <= span.start && span.end <= muted.end {
			return
		}
	}
	emit(c, code, span, ..args)
}

// emit drops a diagnostic about a file outside this partition. A checker reads such a file to learn
// the type of a name used in its own, and would otherwise report what it finds there, which the
// checker that owns the file reports as well. Since every file belongs to exactly one partition,
// dropping it here is what makes one partition and any other split give the same diagnostics.
//
// It drops arguments past diag.MAX_ARGS: a text that needs more than the registry holds is a text
// to rewrite.
@(private)
emit :: proc(c: ^Checker, code: diag.Code, span: source.Span, args: ..string) {
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

@(private)
report_types :: proc(c: ^Checker, code: diag.Code, span: source.Span, a, b: Type_ID) {
	report(c, code, span, text_of(c, a), text_of(c, b))
}

// text_of allocates from the checker's allocator, because a diagnostic borrows its arguments and
// outlives any scratch.
@(private)
text_of :: proc(c: ^Checker, id: Type_ID) -> string {
	return type_text(c.table.types[:], id, c.allocator)
}

@(private)
span_of :: proc(c: ^Checker, id: ast.Node_ID) -> source.Span {
	return c.at.tree.nodes[id].span
}

// fits shares one trail across the whole check: assignable reads the frozen rows and never calls
// back here, so no second comparison can be running while this one is.
//
// A yes records the widenings it accepted, whoever asked. Nothing filters by the question: a pair
// recorded where no value flows only joins two layouts that need not have been joined. `functions`
// false leaves out the pair of two function types at the top of the flow (list_widenings).
@(private)
fits :: proc(c: ^Checker, source, target: Type_ID, functions := true) -> bool {
	clear(&c.trail)
	if !assignable(c.table.types[:], source, target, &c.trail) {
		return false
	}
	list_widenings(c.table.types[:], source, target, &c.widenings, &c.trail, functions)
	return true
}

// note_write records a store into a field or an element; an assignment to a variable stores into no
// cell. The list repeats freely, since freeze drops the repeats once.
@(private)
note_write :: proc(c: ^Checker, target: ast.Node_ID, slot: Type_ID) {
	if c.at.node_types == nil {
		return
	}
	#partial switch v in c.at.tree.nodes[target].variant {
	case ast.Member:
		append(&c.writes, Write{through = c.at.node_types[v.object], slot = slot})
	case ast.Index:
		append(&c.writes, Write{through = c.at.node_types[v.object], slot = slot})
	}
}

// note_array_write records a call of a method of the lib that may change its array: no write for
// one that only reads, a write of nothing new for pop and sort, of an element for any other, push
// among them. So a method added to the lib counts as a write until it is listed as a reader, since
// a write check missed crashes lower on the first view of the array.
@(private)
note_array_write :: proc(c: ^Checker, callee: ast.Node_ID) {
	member, is_member := c.at.tree.nodes[callee].variant.(ast.Member)
	if !is_member || c.at.node_types == nil {
		return
	}
	through := c.at.node_types[member.object]
	array, is_array := c.table.types[through].(Array)
	if !is_array {
		return
	}
	switch member.name.text {
	case "indexOf", "includes", "slice", "join", "map", "filter", "forEach", "reduce":
	case "pop", "sort":
		append(&c.writes, Write{through = through, slot = VOID})
	case:
		append(&c.writes, Write{through = through, slot = array.element})
	}
}

// comparable reports whether two types have a value in common, which is what `===` and a `switch`
// case ask: a comparison of two types that can never be equal is a mistake rather than a test, and
// it is also the question narrowing asks of each member of a union.
//
// Where neither type fits the other, the members are asked one pair at a time, because `"a" | "b"`
// and `"b" | "c"` do have a value in common. `as` asks the narrower question itself, in check_as.
//
// The error type and `any` fit in both directions and everything fits `unknown`, so a value the
// rules have already given up on never produces a second message here.
@(private)
comparable :: proc(c: ^Checker, a, b: Type_ID) -> bool {
	if fits(c, a, b) || fits(c, b, a) {
		return true
	}
	for left in union_members(c, a) {
		for right in union_members(c, b) {
			if fits(c, left, right) || fits(c, right, left) {
				return true
			}
		}
	}
	return false
}

@(private)
union_of :: proc(c: ^Checker, a, b: Type_ID) -> Type_ID {
	pair := [2]Type_ID{a, b}
	return union_type(&c.table, pair[:])
}
