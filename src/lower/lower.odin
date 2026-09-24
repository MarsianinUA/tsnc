/*
The typed program becomes IR here. lower is the last phase that knows what TypeScript is: it reads
the frozen Program and the typing facts of check, and answers a Program_IR in which every rule is an
instruction. codegen below it knows only the instruction set.

Scope of this build (T5.8): numbers, booleans, null, undefined, strings and their operations,
objects, arrays and their methods, `for...of`, functions, arrows and closures as values, calls
direct and through a value, the whole of control flow, module initialization and the entry point.
An arrow passed straight to map, filter, forEach or reduce is inlined where it is called. Union
narrowing is part of the v1 language and is reported as Not_Lowered until T5.9 builds it, so a
program outside the build gets a compile error with a place in it and never a wrong program.

Shape of the output:
- One IR function per module, init$m<N>, holding that module's top-level code.
- One IR function per TypeScript function declaration, m<N>.<name>, and per arrow that is not
  inlined, m<N>.<name>$<node>, named after the binding it initializes or `arrow`.
- One IR global per module-level binding, m<N>.<name>.
- tsnc_main calls the module init functions in turn and returns. First it fills the global
  process.argv, which exists only in a program that reads it.

Which modules run. Program.init_order lists every file once, the lib among them, and a module that
only an `import type` reaches: Node never loads such a module, so its top-level code must not run
either. lower walks the value edges from the entry file itself and keeps the order to those.

Zero before use. Each module init opens by storing the zero of its type into every global of the
module, and each function opens by giving every local of its body the zero of its type. The data
segment is zero already; the stores are what make the rule visible and what gives a string binding a
real empty cell instead of a null pointer the collector would have to know about. A read that
happens before the declaration ran therefore answers the zero value, where Node throws a
ReferenceError. check does not catch that case, and requirements 3.8 keeps such a program out of the
differential tests.

Memory: everything in the answer comes from the allocator, which is meant to be an arena. Names are
built with it, because ir borrows them and they outlive the call; the tables lower needs only while
walking come from context.temp_allocator, which it never rewinds. A rewind would be wrong rather
than merely untidy: a caller may hand the same temp allocator in as the phase allocator, as the
tests do, and the IR built after a mark would go with the scratch. Resetting the scratch of a phase
belongs to whoever owns the frame, which T6.2 settles for every phase at once.
*/
package lower

import "base:runtime"
import "core:fmt"

import "../abi"
import "../ast"
import "../bind"
import "../check"
import "../diag"
import "../ir"
import "../program"
import "../source"

// ENTRY is the file the program starts from: driver puts the lib in first, then the input file.
ENTRY :: source.File_ID(1)

// Decl_Key carries the file because an ast.Node_ID is dense only within its file.
Decl_Key :: struct {
	file: source.File_ID,
	node: ast.Node_ID,
}

// Facts has both fields nil for the lib, which no partition contains, and for a file no checker
// typed.
Facts :: struct {
	result: ^check.Check_Result,
	typed:  ^check.Typed_File,
}

Lowering :: struct {
	prog:            ^program.Program,
	facts:           []Facts, // indexed by source.File_ID
	reachable:       []bool, // indexed by source.File_ID: reached from ENTRY over value imports
	builder:         ir.Program_Builder,
	funcs:           map[Decl_Key]ir.Func_ID, // by ast.Function_Decl, or ast.Arrow not inlined
	globals:         map[Decl_Key]ir.Global_ID, // by ast.Declarator
	closures:        []File_Closures, // indexed by source.File_ID; a file that runs only
	// argv holds process.argv, made the first time the program reads it and filled once by main.
	argv:            Maybe(ir.Global_ID),
	// The widening classes (types.odin), built before any body: the node of each shallow key that
	// takes part in a widening, the union-find link of each node, and each node's slots, which a
	// class root holds joined over the whole class.
	classes:         map[string]int,
	class_links:     [dynamic]int,
	class_slots:     [dynamic][]ir.Slot,
	// The signature classes (types.odin), built the same way over the signature of each function
	// type that takes part in a flow.
	signatures:      map[string]int,
	signature_links: [dynamic]int,
	signature_joins: [dynamic]Signature,
	// The comparators that adapt a closure to what the array sort calls (arrays.odin), by the class
	// signature, the element kind and the number of arguments the closure takes.
	sort_adapters:   map[string]ir.Func_ID,
	diagnostics:     [dynamic]diag.Diagnostic,
	allocator:       runtime.Allocator,
}

// lower borrows the program and the check results, which must outlive the answer, and reports every
// construct of the v1 language this build cannot compile yet.
@(require_results)
lower :: proc(
	prog: ^program.Program,
	results: []check.Check_Result,
	allocator := context.allocator,
) -> (
	out: ir.Program_IR,
	diagnostics: []diag.Diagnostic,
) {
	ensure(len(prog.files) > int(ENTRY), "lower needs an entry file after the lib")

	// Only the builder and the diagnostics outlive the call; the tables that answer "where does
	// this name live" are scratch, and ir.finish copies the initialization order it is given.
	low := Lowering {
		prog            = prog,
		facts           = make([]Facts, len(prog.files), context.temp_allocator),
		reachable       = make([]bool, len(prog.files), context.temp_allocator),
		builder         = ir.make_builder(allocator),
		funcs           = make(map[Decl_Key]ir.Func_ID, context.temp_allocator),
		globals         = make(map[Decl_Key]ir.Global_ID, context.temp_allocator),
		closures        = make([]File_Closures, len(prog.files), context.temp_allocator),
		classes         = make(map[string]int, context.temp_allocator),
		class_links     = make([dynamic]int, context.temp_allocator),
		class_slots     = make([dynamic][]ir.Slot, context.temp_allocator),
		signatures      = make(map[string]int, context.temp_allocator),
		signature_links = make([dynamic]int, context.temp_allocator),
		signature_joins = make([dynamic]Signature, context.temp_allocator),
		sort_adapters   = make(map[string]ir.Func_ID, context.temp_allocator),
		diagnostics     = make([dynamic]diag.Diagnostic, allocator),
		allocator       = allocator,
	}
	index_facts(&low, results)
	// Every layout an object type ends up in is known before the first one is interned, and every
	// signature a function type ends up with before the first function is declared.
	build_classes(&low, results)
	build_signature_classes(&low, results)
	mark_reachable(&low)
	order := module_order(&low)
	for file in order {
		ensure(low.facts[file].typed != nil, "a module that runs was never typed by any checker")
		low.closures[file] = analyze_closures(&low, file)
	}

	// Declare before defining: a call may name a function whose body is built later, and a module
	// init calls functions declared below it.
	inits := make([]ir.Func_ID, len(order), context.temp_allocator)
	for file, i in order {
		name := fmt.aprintf("init$m%d", file, allocator = allocator)
		inits[i] = ir.declare_func(&low.builder, name, nil, ir.VOID, module_span(&low, file))
	}
	for file in order {
		declare_functions(&low, file)
	}
	for file in order {
		declare_globals(&low, file)
	}
	main := ir.declare_func(&low.builder, abi.MAIN_SYMBOL, nil, ir.VOID, module_span(&low, ENTRY))

	for file, i in order {
		build_module_init(&low, file, inits[i])
	}
	for file in order {
		build_functions(&low, file)
	}
	build_main(&low, main, inits)

	return ir.finish(&low.builder, main, inits), low.diagnostics[:]
}

// report is called once for a construct the slice does not build yet, where it stands; what depends
// on it answers a poison value and says nothing more.
report :: proc(low: ^Lowering, code: diag.Code, span: source.Span, args: ..string) {
	d := diag.Diagnostic {
		code = code,
		span = span,
	}
	for arg, i in args {
		d.args[i] = arg
	}
	append(&low.diagnostics, d)
}

// fail_site names where a check that fails at run time stands. Only source turns an offset into a
// line and a column, which is why the site is resolved here (see the ir package doc).
@(private)
fail_site :: proc(low: ^Lowering, span: source.Span, error: abi.Runtime_Error) -> ir.Fail_Site_ID {
	file := low.prog.files[span.file]
	at := source.position(file, span.start)
	site := abi.Fail_Site {
		file   = file.path,
		line   = at.line,
		column = at.column,
		error  = error,
	}
	return ir.fail_site(&low.builder, site)
}

// index_facts gives every file of a partition the result that typed it, so a later lookup is an
// index rather than a scan of every result.
@(private)
index_facts :: proc(low: ^Lowering, results: []check.Check_Result) {
	for &result in results {
		for &typed in result.files {
			low.facts[typed.file] = {
				result = &result,
				typed  = &typed,
			}
		}
	}
}

// mark_reachable skips an `import type` edge: it is erased before the program runs, so a module
// only it reaches never loads and never initializes.
@(private)
mark_reachable :: proc(low: ^Lowering) {
	queue := make([dynamic]source.File_ID, 0, len(low.prog.files), context.temp_allocator)
	append(&queue, ENTRY)
	low.reachable[ENTRY] = true
	for i := 0; i < len(queue); i += 1 {
		for edge in low.prog.imports[queue[i]] {
			if edge.type_only || low.reachable[edge.module] {
				continue
			}
			low.reachable[edge.module] = true
			append(&queue, edge.module)
		}
	}
}

// module_order is the initialization order with the modules that never load left out: the lib,
// which declares and runs nothing, and whatever no value import reaches.
@(private)
module_order :: proc(low: ^Lowering) -> []source.File_ID {
	order := make([dynamic]source.File_ID, 0, len(low.prog.files), context.temp_allocator)
	for file in low.prog.init_order {
		if file != program.LIB && low.reachable[file] {
			append(&order, file)
		}
	}
	return order[:]
}

@(private)
module_span :: proc(low: ^Lowering, file: source.File_ID) -> source.Span {
	return low.prog.trees[file].nodes[ast.ROOT].span
}

// declare_functions declares every closure of the file (closures.odin), nested ones included,
// before any body is built, which is what lets two of them call each other. Each takes the
// signature of its class and the environment its captures need. A closure whose own signature
// this build cannot represent is reported and left out; a call to it then finds nothing and stays
// quiet.
@(private)
declare_functions :: proc(low: ^Lowering, file: source.File_ID) {
	tree := &low.prog.trees[file]
	bound := &low.prog.bound[file]
	typed := low.facts[file].typed
	types := low.facts[file].result.types

	for id in low.closures[file].functions {
		params: []ast.Node_ID
		name_span := tree.nodes[id].span
		#partial switch v in tree.nodes[id].variant {
		case ast.Function_Decl:
			params, name_span = v.params, v.name.span
		case ast.Arrow:
			params = v.params
		}
		function, is_function := types[typed.node_types[id]].(check.Function)
		if !is_function {
			continue
		}
		if function.variadic {
			report(low, .Not_Lowered, name_span, "rest parameters")
			continue
		}
		if _, ok := param_types(low, file, params); !ok {
			continue
		}
		if _, ok := ir_type(low, types, function.result); !ok {
			report(low, .Not_Lowered, name_span, construct_text(types, function.result))
			continue
		}
		env, env_ok := env_layout(low, file, id)
		if !env_ok {
			continue
		}

		signature, _ := signature_of(low, types, typed.node_types[id])
		name := function_name(low, file, bound, id)
		span := tree.nodes[id].span
		low.funcs[{file, id}] = ir.declare_func(
			&low.builder,
			name,
			signature.params,
			signature.result,
			span,
			env,
		)
	}
}

// env_layout has a slot per symbol of the closure's environment: the box of a boxed one, the value
// itself otherwise. A symbol with no representation answers false and says nothing: it was, or will
// be, reported where it is declared.
@(private)
env_layout :: proc(
	low: ^Lowering,
	file: source.File_ID,
	function: ast.Node_ID,
) -> (
	layout: ir.Layout_ID,
	ok: bool,
) {
	symbols := low.closures[file].env[function]
	if len(symbols) == 0 {
		return ir.NO_LAYOUT, true
	}
	slots := make([]abi.Slot_Kind, len(symbols), context.temp_allocator)
	for symbol, i in symbols {
		type := symbol_type(low, file, symbol) or_return
		slots[i] = .Ref if low.closures[file].boxed[symbol] else slot_of(type.kind)
	}
	return ir.environment_layout(&low.builder, slots), true
}

// symbol_type is the IR type of what a variable holds, or a closure for a nested declaration.
@(private)
symbol_type :: proc(
	low: ^Lowering,
	file: source.File_ID,
	symbol: bind.Symbol_ID,
) -> (
	type: ir.Type,
	ok: bool,
) {
	entry := low.prog.bound[file].symbols[symbol]
	if entry.kind == .Function {
		return ir.CLOSURE, true
	}
	return ir_type(
		low,
		low.facts[file].result.types,
		low.facts[file].typed.node_types[entry.declaration],
	)
}

// param_types is the IR type of each parameter as the body sees it: check records `T | undefined`
// on an optional one, which is what a caller may really leave there.
@(private)
param_types :: proc(
	low: ^Lowering,
	file: source.File_ID,
	params: []ast.Node_ID,
) -> (
	[]ir.Type,
	bool,
) {
	tree := &low.prog.trees[file]
	typed := low.facts[file].typed
	types := low.facts[file].result.types

	out := make([]ir.Type, len(params), context.temp_allocator)
	for id, i in params {
		type, ok := ir_type(low, types, typed.node_types[id])
		if !ok {
			node := tree.nodes[id].variant.(ast.Param)
			report(low, .Not_Lowered, node.name.span, construct_text(types, typed.node_types[id]))
			return nil, false
		}
		out[i] = type
	}
	return out, true
}

// function_name is the symbol codegen emits. A module scope holds one symbol per name, so the
// module number and the name are enough there; a function declared inside another one takes its
// node number as well, since two of them may share a name, and so does an arrow, which is named
// after what Node names its value, or `arrow`.
@(private)
function_name :: proc(
	low: ^Lowering,
	file: source.File_ID,
	bound: ^bind.Bound_File,
	id: ast.Node_ID,
) -> string {
	name := low.closures[file].names[id]
	if _, is_arrow := low.prog.trees[file].nodes[id].variant.(ast.Arrow); is_arrow {
		name = name if name != "" else "arrow"
		return fmt.aprintf("m%d.%s$%d", file, name, id, allocator = low.allocator)
	}
	symbol := bound.node_symbols[id]
	if symbol != bind.NO_SYMBOL && bound.symbols[symbol].scope == bind.MODULE_SCOPE {
		return fmt.aprintf("m%d.%s", file, name, allocator = low.allocator)
	}
	return fmt.aprintf("m%d.%s$%d", file, name, id, allocator = low.allocator)
}

// declare_globals numbers the globals of a program the same way on every run, because the module
// scope lists its symbols in source order.
@(private)
declare_globals :: proc(low: ^Lowering, file: source.File_ID) {
	tree := &low.prog.trees[file]
	bound := &low.prog.bound[file]
	typed := low.facts[file].typed
	types := low.facts[file].result.types

	for symbol in bound.scopes[bind.MODULE_SCOPE].symbols {
		entry := bound.symbols[symbol]
		if entry.kind != .Let && entry.kind != .Const {
			continue
		}
		declared := typed.node_types[entry.declaration]
		type, ok := ir_type(low, types, declared)
		if !ok {
			span := tree.nodes[entry.declaration].span
			report(low, .Not_Lowered, span, construct_text(types, declared))
			continue
		}
		name := fmt.aprintf("m%d.%s", file, entry.name.text, allocator = low.allocator)
		low.globals[{file, entry.declaration}] = ir.add_global(&low.builder, name, type)
	}
}

@(private)
build_main :: proc(low: ^Lowering, main: ir.Func_ID, inits: []ir.Func_ID) {
	span := module_span(low, ENTRY)
	f := ir.begin_func(&low.builder, main)
	// Before any module runs, since any of them may read it.
	if argv, used := low.argv.?; used {
		type := low.builder.globals[argv].type
		array := ir.emit(&f, type, ir.Call_Runtime{export = .Process_Argv}, span)
		ir.emit(&f, ir.VOID, ir.Global_Store{global = argv, value = array}, span)
	}
	for id in inits {
		ir.emit(&f, ir.VOID, ir.Call{func = id}, span)
	}
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, span)
	ir.end_func(&f)
}
