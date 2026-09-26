package lower

import "core:slice"

import "../abi"
import "../ast"
import "../bind"
import "../check"
import "../ir"
import "../source"

/*
Bindings and joins. The IR has no stack slot, so a local variable is an SSA value and a place where
control comes together needs a phi.

One array holds the current value of every local of the function being built: its own variables
and parameters, those of the arrows inlined into it, and what its environment holds (File_Locals).
bind gives each declaration a symbol of its own, so two blocks that both declare `x` never collide
and the array needs no scope stack. It is dense and in symbol order, numbered through a table the
size of the file's symbols that holds the numbers of one function at a time: a join copies and
compares only what the function has, which keeps a file of many small functions linear. Every local
of a function is given the zero of its type in the entry block, which is the rule of the package doc
and also what makes the array total: a read always finds a value, and a join can compare the two
sides local by local.

A variable a closure shares (closures.odin) lives in a box instead, and its entry in the array is
the box, made when its scope is entered (enter_scope) or when it is bound. Every read and write of a
local goes through read_local, write_local and bind_local, which are the one place that knows.

A join takes the edges that reach it, each carrying the block control left and a copy of that array.
Opening the block creates one phi per symbol the edges disagree about, walked in symbol order so the
IR of one program is the same on every run. A loop header cannot wait for its edges, so it takes a
phi for every symbol the loop assigns, found by a walk over the loop statement before its body is
built; an extra phi for a symbol that turns out unchanged is dead and costs nothing.
*/

// Edge is one way into a join: the block control left, and the locals as they stood there.
Edge :: struct {
	block:  ir.Block_ID,
	values: []ir.Value_ID,
}

// Loop_Frame is the innermost `break` and `continue` target. A switch pushes one with no latch:
// `continue` inside it belongs to the loop around it.
Loop_Frame :: struct {
	latch:     ir.Block_ID, // where `continue` goes, NO_BLOCK in a switch
	exit:      ir.Block_ID, // where `break` goes
	continues: [dynamic]Edge,
	breaks:    [dynamic]Edge,
}

// Inline_Frame is an arrow being inlined into the loop of map, filter, forEach or reduce. Its
// `return` is a jump to join rather than a Return of the function around it.
Inline_Frame :: struct {
	join:   ir.Block_ID,
	edges:  [dynamic]Edge,
	values: [dynamic]ir.Value_ID, // one per edge
}

Func_State :: struct {
	low:      ^Lowering,
	fb:       ir.Func_Builder,
	file:     source.File_ID,
	tree:     ^ast.File_AST,
	bound:    ^bind.Bound_File,
	typed:    ^check.Typed_File,
	types:    []check.Type,
	// What a `return` produces: the result of the function's signature class, and its own
	// declared result, which the class may hold boxed (types.odin). Inside an inlined arrow,
	// declared and returns are the arrow's (inline_arrow).
	result:   ir.Type,
	declared: ir.Type,
	returns:  check.Type_ID, // the declared result as check typed it; ERROR outside a function
	// The symbols of the function's locals (File_Locals.locals), and by the position of each there
	// (local_at): its value, or its box, and whether zero_locals reported it. The value is NO_VALUE
	// for a box whose scope has not been entered and for a variable refused.
	symbols:  []bind.Symbol_ID,
	locals:   []ir.Value_ID,
	refused:  []bool,
	loops:    [dynamic]Loop_Frame,
	inlines:  [dynamic]Inline_Frame, // the innermost last
}

// File_Locals groups the locals of a file by the function that holds them, once per file.
File_Locals :: struct {
	// By the Scope_ID of a function scope, an inlined arrow's too, and MODULE_SCOPE: the variables
	// and parameters of the scopes it is the nearest function of, in the order zero_locals gives
	// them their zero, which is scope order.
	zeroed: [][]bind.Symbol_ID,
	// By the Scope_ID of a function lower builds, and MODULE_SCOPE for the module init: every
	// symbol its body holds as a local, in symbol order.
	locals: [][]bind.Symbol_ID,
	// By bind.Symbol_ID: the position of a local among the locals of the function being built, and
	// -1 for any other symbol. begin_function fills it and end_function clears it again.
	index:  []i32,
}

// group_locals finds each function of the file its scopes: the nearest one, and the one lower
// builds, which for an inlined arrow is the function it is inlined into. Two passes of counting
// place every list in one flat array.
@(private)
group_locals :: proc(low: ^Lowering, file: source.File_ID) -> File_Locals {
	bound := &low.prog.bound[file]
	closures := &low.closures[file]
	scope_count := len(bound.scopes)
	nearest := make([]bind.Scope_ID, scope_count, context.temp_allocator)
	home := make([]bind.Scope_ID, scope_count, context.temp_allocator)
	for scope, i in bound.scopes[1:] {
		id := bind.Scope_ID(i + 1)
		ensure(scope.parent < id, "bind opens a scope after the scope around it")
		is_function := scope.kind == .Function
		nearest[id] = id if is_function else nearest[scope.parent]
		home[id] = id if is_function && !closures.inlined[scope.node] else home[scope.parent]
	}

	zeroed_counts := make([]int, scope_count, context.temp_allocator)
	local_counts := make([]int, scope_count, context.temp_allocator)
	for scope, i in bound.scopes[1:] {
		for symbol in scope.symbols {
			#partial switch bound.symbols[symbol].kind {
			case .Let, .Const, .Param:
				zeroed_counts[nearest[i + 1]] += 1
			}
		}
	}
	for entry in bound.symbols[1:] {
		#partial switch entry.kind {
		case .Let, .Const, .Param, .Function:
			if entry.scope != bind.MODULE_SCOPE {
				local_counts[home[entry.scope]] += 1
			}
		}
	}
	for id in closures.functions {
		local_counts[bound.node_scopes[id]] += len(closures.env[id])
	}

	out := File_Locals {
		zeroed = flat_lists(zeroed_counts),
		locals = flat_lists(local_counts),
		index  = make([]i32, len(bound.symbols), context.temp_allocator),
	}
	slice.fill(out.index, -1)
	slice.fill(zeroed_counts, 0)
	slice.fill(local_counts, 0)
	for scope, i in bound.scopes[1:] {
		for symbol in scope.symbols {
			#partial switch bound.symbols[symbol].kind {
			case .Let, .Const, .Param:
				key := nearest[i + 1]
				out.zeroed[key][zeroed_counts[key]] = symbol
				zeroed_counts[key] += 1
			}
		}
	}
	for entry, symbol in bound.symbols[1:] {
		#partial switch entry.kind {
		case .Let, .Const, .Param, .Function:
			if entry.scope == bind.MODULE_SCOPE {
				continue
			}
			key := home[entry.scope]
			out.locals[key][local_counts[key]] = bind.Symbol_ID(symbol + 1)
			local_counts[key] += 1
		}
	}
	for id in closures.functions {
		if env := closures.env[id]; len(env) > 0 {
			key := bound.node_scopes[id]
			copy(out.locals[key][local_counts[key]:], env)
			slice.sort(out.locals[key])
		}
	}
	return out
}

// flat_lists cuts one array into a list per key, of the length its count gives.
@(private)
flat_lists :: proc(counts: []int) -> [][]bind.Symbol_ID {
	total := 0
	for count in counts {
		total += count
	}
	flat := make([]bind.Symbol_ID, total, context.temp_allocator)
	lists := make([][]bind.Symbol_ID, len(counts), context.temp_allocator)
	start := 0
	for count, key in counts {
		lists[key] = flat[start:][:count]
		start += count
	}
	return lists
}

// begin_function opens the body of a function: node is its declaration or arrow, ast.ROOT for a
// module init. A closure first takes what its environment holds, then each parameter, which
// arrives in the type of the signature class and is unboxed into its own.
@(private)
begin_function :: proc(
	low: ^Lowering,
	file: source.File_ID,
	id: ir.Func_ID,
	node: ast.Node_ID,
	scope: bind.Scope_ID,
	params: []ast.Node_ID,
	span: source.Span,
) -> Func_State {
	s := Func_State {
		low      = low,
		fb       = ir.begin_func(&low.builder, id),
		file     = file,
		tree     = &low.prog.trees[file],
		bound    = &low.prog.bound[file],
		typed    = low.facts[file].typed,
		types    = low.facts[file].result.types,
		result   = low.builder.funcs[id].result,
		declared = ir.VOID,
		returns  = check.ERROR,
		loops    = make([dynamic]Loop_Frame, context.temp_allocator),
		inlines  = make([dynamic]Inline_Frame, context.temp_allocator),
	}
	s.symbols = low.locals[file].locals[scope]
	for symbol, i in s.symbols {
		low.locals[file].index[symbol] = i32(i)
	}
	s.locals = make([]ir.Value_ID, len(s.symbols), context.temp_allocator)
	slice.fill(s.locals, ir.NO_VALUE)
	s.refused = make([]bool, len(s.symbols), context.temp_allocator)
	if node != ast.ROOT {
		function := s.types[s.typed.node_types[node]].(check.Function)
		s.returns = function.result
		s.declared, _ = ir_type(low, s.types, function.result)
	}

	zero_locals(&s, scope, span)
	if env := low.builder.funcs[id].env; env != ir.NO_LAYOUT {
		cell := ir.emit(&s.fb, ir.ref(env), ir.Env{}, span)
		for symbol, i in low.closures[file].env[node] {
			type := local_type(&s, symbol)
			if low.closures[file].boxed[symbol] {
				type = local_box_type(&s, symbol)
			}
			load := ir.Field_Load {
				cell  = cell,
				field = i32(i),
			}
			s.locals[local_at(&s, symbol)] = ir.emit(&s.fb, type, load, span)
		}
	}
	for param, i in params {
		symbol := s.bound.node_symbols[param]
		if symbol == bind.NO_SYMBOL || is_refused(&s, symbol) {
			continue
		}
		value := coerce(&s, ir.Value_ID(i), local_type(&s, symbol), span, .Value_Of_Other_Kind)
		bind_local(&s, symbol, value, span)
	}
	return s
}

// end_function closes the body and gives the numbers of its locals back, so the next function of
// the file numbers its own.
@(private)
end_function :: proc(s: ^Func_State) {
	for symbol in s.symbols {
		s.low.locals[s.file].index[symbol] = -1
	}
	ir.end_func(&s.fb)
}

// local_at is the position of a symbol among the locals of the function being built, and -1 for a
// symbol of another function.
@(private)
local_at :: proc(s: ^Func_State, symbol: bind.Symbol_ID) -> int {
	return int(s.low.locals[s.file].index[symbol])
}

// local_value answers NO_VALUE for a symbol of another function.
@(private)
local_value :: proc(s: ^Func_State, symbol: bind.Symbol_ID) -> ir.Value_ID {
	at := local_at(s, symbol)
	return s.locals[at] if at >= 0 else ir.NO_VALUE
}

@(private)
is_refused :: proc(s: ^Func_State, symbol: bind.Symbol_ID) -> bool {
	at := local_at(s, symbol)
	return at >= 0 && s.refused[at]
}

// zero_locals takes a body to be the scopes whose nearest enclosing function is this one; the
// module scope is left out of the module init, because its bindings are globals of the program and
// not values of a function.
@(private)
zero_locals :: proc(s: ^Func_State, scope: bind.Scope_ID, span: source.Span) {
	for symbol in s.low.locals[s.file].zeroed[scope] {
		declared := s.bound.symbols[symbol]
		type, ok := binding_type(s.low, s.types, s.typed.node_types[declared.declaration])
		if !ok {
			node := s.tree.nodes[declared.declaration]
			text := construct_text(s.types, s.typed.node_types[declared.declaration])
			report(s.low, .Not_Lowered, node.span, text)
			s.refused[local_at(s, symbol)] = true
			continue
		}
		// A box is made where its scope is entered, or where its variable is bound.
		if !s.low.closures[s.file].boxed[symbol] {
			s.locals[local_at(s, symbol)] = zero_value(s, type, span)
		}
	}
}

// enter_scope makes what a block, a `for` or a `switch` holds before its first statement runs: the
// boxes of its variables, each holding the zero of its type, then the closures of the function
// declarations hoisted there, in source order, since any statement of the scope may call one. The
// module scope holds globals, and the variable of a `for...of` is bound at every step instead.
@(private)
enter_scope :: proc(s: ^Func_State, scope: bind.Scope_ID, span: source.Span) {
	if scope == bind.MODULE_SCOPE {
		return
	}
	facts := &s.low.closures[s.file]
	for symbol in s.bound.scopes[scope].symbols {
		entry := s.bound.symbols[symbol]
		is_variable := entry.kind == .Let || entry.kind == .Const || entry.kind == .Function
		if !is_variable || !facts.boxed[symbol] || is_refused(s, symbol) {
			continue
		}
		if facts.checked[symbol] {
			// The cell comes zero filled: null, or a zero with its ready flag false.
			type := local_box_type(s, symbol)
			box := ir.emit(&s.fb, type, ir.Alloc{layout = type.layout}, span)
			s.locals[local_at(s, symbol)] = box
		} else {
			bind_local(s, symbol, zero_value(s, local_type(s, symbol), span), span)
		}
	}
	for symbol in s.bound.scopes[scope].symbols {
		entry := s.bound.symbols[symbol]
		if entry.kind != .Function {
			continue
		}
		if called_directly(s.bound, facts, symbol) {
			continue
		}
		write_local(s, symbol, make_closure(s, entry.declaration, span), span)
	}
}

// local_type is the type of what a local holds, never of its box.
@(private)
local_type :: proc(s: ^Func_State, symbol: bind.Symbol_ID) -> ir.Type {
	type, _ := symbol_type(s.low, s.file, symbol)
	return type
}

// box_type is the type of a box holding a value of this type: an environment of one slot.
@(private)
box_type :: proc(s: ^Func_State, type: ir.Type) -> ir.Type {
	slots := [1]abi.Slot_Kind{slot_of(type.kind)}
	return ir.ref(ir.environment_layout(&s.low.builder, slots[:]))
}

// local_box_type is the box of a local. Where a read may come before the declaration ran and the
// local is no reference, a second slot holds its ready flag (check_ready).
@(private)
local_box_type :: proc(s: ^Func_State, symbol: bind.Symbol_ID) -> ir.Type {
	type := local_type(s, symbol)
	if !s.low.closures[s.file].checked[symbol] || holds_null(type) {
		return box_type(s, type)
	}
	slots := [2]abi.Slot_Kind{slot_of(type.kind), .Boolean}
	return ir.ref(ir.environment_layout(&s.low.builder, slots[:]))
}

// read_local answers NO_VALUE for a local that was refused, or that holds nothing yet.
@(private)
read_local :: proc(s: ^Func_State, symbol: bind.Symbol_ID, span: source.Span) -> ir.Value_ID {
	value := local_value(s, symbol)
	if value == ir.NO_VALUE || !s.low.closures[s.file].boxed[symbol] {
		return value
	}
	load := ir.Field_Load {
		cell  = value,
		field = 0,
	}
	return ir.emit(&s.fb, local_type(s, symbol), load, span)
}

// write_local gives a local a new value where it already lives: into its box, which every closure
// that shares it reads.
@(private)
write_local :: proc(
	s: ^Func_State,
	symbol: bind.Symbol_ID,
	value: ir.Value_ID,
	span: source.Span,
) {
	if value == ir.NO_VALUE {
		return
	}
	if !s.low.closures[s.file].boxed[symbol] {
		s.locals[local_at(s, symbol)] = value
		return
	}
	if box := local_value(s, symbol); box != ir.NO_VALUE {
		store_slot(s, box, 0, value, span)
	}
}

// bind_local starts a new binding of a local: a boxed one gets a box of its own, so the closures made
// before keep the one they share.
@(private)
bind_local :: proc(s: ^Func_State, symbol: bind.Symbol_ID, value: ir.Value_ID, span: source.Span) {
	if value == ir.NO_VALUE {
		return
	}
	if !s.low.closures[s.file].boxed[symbol] {
		s.locals[local_at(s, symbol)] = value
		return
	}
	type := local_box_type(s, symbol)
	box := ir.emit(&s.fb, type, ir.Alloc{layout = type.layout}, span)
	store_slot(s, box, 0, value, span)
	s.locals[local_at(s, symbol)] = box
	mark_ready(s, symbol, span)
}

// check_ready fails the program where a `let` or `const` read before its declaration ran
// (early_use) finds it has not. A reference binding holds null until then, any other a ready flag
// beside it: a global of its own for a global, the second slot of the box for a local. A local no
// closure shares, which no box holds, is read early only by an arrow inlined before its
// declaration, and that read always comes first.
@(private)
check_ready :: proc(s: ^Func_State, symbol: bind.Symbol_ID, span: source.Span) {
	declaration := s.bound.symbols[symbol].declaration
	not_yet := ir.NO_VALUE
	if global, is_global := s.low.globals[{s.file, declaration}]; is_global {
		type := s.low.builder.globals[global].type
		if flag, has_flag := s.low.ready[{s.file, declaration}]; has_flag {
			ready := ir.emit(&s.fb, ir.BOOL, ir.Global_Load{global = flag}, span)
			not_yet = negated(s, ready, span)
		} else {
			value := ir.emit(&s.fb, type, ir.Global_Load{global = global}, span)
			not_yet = ir.emit(&s.fb, ir.BOOL, ir.Null_Test{value = value}, span)
		}
	} else if !s.low.closures[s.file].boxed[symbol] {
		not_yet = ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = true}, span)
	} else {
		box := local_value(s, symbol)
		if box == ir.NO_VALUE {
			return // refused where it is declared
		}
		type := local_type(s, symbol)
		if holds_null(type) {
			value := ir.emit(&s.fb, type, ir.Field_Load{cell = box, field = 0}, span)
			not_yet = ir.emit(&s.fb, ir.BOOL, ir.Null_Test{value = value}, span)
		} else {
			ready := ir.emit(&s.fb, ir.BOOL, ir.Field_Load{cell = box, field = 1}, span)
			not_yet = negated(s, ready, span)
		}
	}
	fail_if(s, not_yet, .Read_Before_Initialization, span)
}

// mark_ready is the other half of check_ready: the declaration of a binding that a read may reach
// early has run. A reference binding needs no mark, since the value it now holds is not null.
@(private)
mark_ready :: proc(s: ^Func_State, symbol: bind.Symbol_ID, span: source.Span) {
	if !s.low.closures[s.file].checked[symbol] || holds_null(local_type(s, symbol)) {
		return
	}
	ready := ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = true}, span)
	declaration := s.bound.symbols[symbol].declaration
	if flag, has_flag := s.low.ready[{s.file, declaration}]; has_flag {
		ir.emit(&s.fb, ir.VOID, ir.Global_Store{global = flag, value = ready}, span)
	} else if s.low.closures[s.file].boxed[symbol] {
		if box := local_value(s, symbol); box != ir.NO_VALUE {
			store_slot(s, box, 1, ready, span)
		}
	}
}

// holds_null says whether a binding of this type is a reference, which is null before anything was
// stored in it.
@(private)
holds_null :: proc(type: ir.Type) -> bool {
	#partial switch type.kind {
	case .Str, .Ref, .Closure:
		return true
	}
	return false
}

// store_slot writes a slot of a cell, through the store that ends in _Ref where the collector
// traces what the slot holds.
@(private)
store_slot :: proc(
	s: ^Func_State,
	cell: ir.Value_ID,
	field: i32,
	value: ir.Value_ID,
	span: source.Span,
) {
	kind := s.low.builder.layouts[value_type(s, cell).layout].fields[field].kind
	if kind == .Ref || kind == .Tagged {
		store := ir.Field_Store_Ref {
			cell  = cell,
			field = field,
			value = value,
		}
		ir.emit(&s.fb, ir.VOID, store, span)
		return
	}
	store := ir.Field_Store {
		cell  = cell,
		field = field,
		value = value,
	}
	ir.emit(&s.fb, ir.VOID, store, span)
}

// zero_value gives a string the empty cell rather than a null pointer, so no reader and no
// collector has to know about one. An object, an array or a function has no empty value to take,
// so its binding starts as the null reference, which the collector skips; a read that may come
// before a value is stored tests for it (check_ready).
@(private)
zero_value :: proc(s: ^Func_State, type: ir.Type, span: source.Span) -> ir.Value_ID {
	switch type.kind {
	case .F64:
		return ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
	case .Bool:
		return ir.emit(&s.fb, ir.BOOL, ir.Const_Bool{value = false}, span)
	case .Tagged:
		return ir.emit(&s.fb, ir.TAGGED, ir.Const_Undefined{}, span)
	case .Str:
		text := ir.intern_string(&s.low.builder, "")
		return ir.emit(&s.fb, ir.STR, ir.Const_String{text = text}, span)
	case .Ref, .Closure:
		return ir.emit(&s.fb, type, ir.Const_Null{}, span)
	case .Void:
		// A binding typed never holds nothing.
		return ir.NO_VALUE
	}
	return ir.NO_VALUE
}

@(private)
here :: proc(s: ^Func_State) -> Edge {
	return {block = s.fb.current, values = slice.clone(s.locals, context.temp_allocator)}
}

// terminated says whether a terminator closed the block, so the statements after it need one of
// their own.
@(private)
terminated :: proc(s: ^Func_State) -> bool {
	return s.fb.current == ir.NO_BLOCK
}

@(private)
value_type :: proc(s: ^Func_State, value: ir.Value_ID) -> ir.Type {
	return s.fb.values[value].type
}

@(private)
tag_test :: proc(
	s: ^Func_State,
	value: ir.Value_ID,
	tags: ir.Tag_Set,
	span: source.Span,
) -> ir.Value_ID {
	return ir.emit(&s.fb, ir.BOOL, ir.Tag_Test{value = value, tags = tags}, span)
}

@(private)
fail_if :: proc(
	s: ^Func_State,
	condition: ir.Value_ID,
	error: abi.Runtime_Error,
	span: source.Span,
) {
	passed := ir.add_block(&s.fb)
	failed := ir.add_block(&s.fb)
	branch := ir.Branch {
		condition  = condition,
		then_block = failed,
		else_block = passed,
	}
	ir.emit(&s.fb, ir.VOID, branch, span)
	fail_block(s, failed, error, span)
	ir.use_block(&s.fb, passed)
}

@(private)
fail_block :: proc(
	s: ^Func_State,
	block: ir.Block_ID,
	error: abi.Runtime_Error,
	span: source.Span,
) {
	ir.use_block(&s.fb, block)
	ir.emit(&s.fb, ir.VOID, ir.Fail{site = fail_site(s.low, span, error)}, span)
}

@(private)
negated :: proc(s: ^Func_State, test: ir.Value_ID, span: source.Span) -> ir.Value_ID {
	return ir.emit(&s.fb, ir.BOOL, ir.Unary{op = .Not, operand = test}, span)
}

// open_join answers false for a block no edge reaches. Such a block cannot be entered, and takes an
// inert terminator so that the statements written after it still have a block to land in.
//
// A local one edge has no value for is left without one: it is a local of an inlined arrow, which
// has a value only inside the loop that holds the arrow, and nothing after the join reads it.
@(private)
open_join :: proc(s: ^Func_State, block: ir.Block_ID, edges: []Edge, span: source.Span) -> bool {
	ir.use_block(&s.fb, block)
	if len(edges) == 0 {
		ir.emit(&s.fb, ir.VOID, ir.Unreachable{}, span)
		return false
	}
	if len(edges) == 1 {
		copy(s.locals, edges[0].values)
		return true
	}

	copy(s.locals, edges[0].values)
	for at in 0 ..< len(s.locals) {
		first := edges[0].values[at]
		same, missing := true, first == ir.NO_VALUE
		for edge in edges[1:] {
			same &&= edge.values[at] == first
			missing ||= edge.values[at] == ir.NO_VALUE
		}
		if missing {
			s.locals[at] = ir.NO_VALUE
			continue
		}
		if same {
			continue
		}
		merged := ir.phi(&s.fb, value_type(s, first), span)
		for edge in edges {
			ir.phi_incoming(&s.fb, merged, edge.block, edge.values[at])
		}
		s.locals[at] = merged
	}
	return true
}

// open_header cannot see its back edge yet, so it takes a phi for every local the loop assigns and
// the phis learn their edges through patch_header.
@(private)
open_header :: proc(
	s: ^Func_State,
	block: ir.Block_ID,
	assigned: []int,
	from: Edge,
	span: source.Span,
) -> (
	phis: []ir.Value_ID,
) {
	ir.use_block(&s.fb, block)
	copy(s.locals, from.values)

	phis = make([]ir.Value_ID, len(assigned), context.temp_allocator)
	for at, i in assigned {
		entering := from.values[at]
		if entering == ir.NO_VALUE {
			phis[i] = ir.NO_VALUE
			continue
		}
		phis[i] = ir.phi(&s.fb, value_type(s, entering), span)
		ir.phi_incoming(&s.fb, phis[i], from.block, entering)
		s.locals[at] = phis[i]
	}
	return
}

@(private)
patch_header :: proc(s: ^Func_State, phis: []ir.Value_ID, assigned: []int, back: Edge) {
	for at, i in assigned {
		if phis[i] != ir.NO_VALUE {
			ir.phi_incoming(&s.fb, phis[i], back.block, back.values[at])
		}
	}
}

// assigned_locals lists the positions of the locals a subtree writes to, and of `also`, in order.
// It is the set a loop header needs a phi for; a local it names that the loop leaves alone only
// costs a dead phi.
@(private)
assigned_locals :: proc(s: ^Func_State, root: ast.Node_ID, also: []bind.Symbol_ID = nil) -> []int {
	found := make([dynamic]int, 0, 8, context.temp_allocator)
	for symbol in also {
		append(&found, local_at(s, symbol))
	}
	stack := make([dynamic]ast.Node_ID, 0, 32, context.temp_allocator)
	append(&stack, root)
	for id in ast.walk(s.tree.nodes, &stack) {
		target := ast.NO_NODE
		#partial switch v in s.tree.nodes[id].variant {
		case ast.Assign:
			target = v.target
		case ast.Update:
			target = v.operand
		}
		if target == ast.NO_NODE {
			continue
		}
		if _, is_ident := s.tree.nodes[target].variant.(ast.Ident); !is_ident {
			continue
		}
		at := local_at(s, s.bound.node_symbols[target])
		if at < 0 || s.locals[at] == ir.NO_VALUE {
			continue
		}
		if !slice.contains(found[:], at) {
			append(&found, at)
		}
	}
	slice.sort(found[:])
	return found[:]
}

// break_frame and continue_frame are the innermost statement each jump leaves. A switch catches a
// `break` and lets a `continue` through, which is why the two differ.
@(private)
break_frame :: proc(s: ^Func_State) -> ^Loop_Frame {
	return &s.loops[len(s.loops) - 1] if len(s.loops) > 0 else nil
}

@(private)
continue_frame :: proc(s: ^Func_State) -> ^Loop_Frame {
	#reverse for &frame in s.loops {
		if frame.latch != ir.NO_BLOCK {
			return &frame
		}
	}
	return nil
}

@(private)
push_frame :: proc(s: ^Func_State, latch, exit: ir.Block_ID) {
	append(
		&s.loops,
		Loop_Frame {
			latch = latch,
			exit = exit,
			continues = make([dynamic]Edge, context.temp_allocator),
			breaks = make([dynamic]Edge, context.temp_allocator),
		},
	)
}
