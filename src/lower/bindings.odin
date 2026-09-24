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

One array holds the current value of every local, indexed by bind.Symbol_ID: bind gives each
declaration a symbol of its own, so two blocks that both declare `x` never collide and the array
needs no scope stack. Every local of a function is given the zero of its type in the entry block,
which is the rule of the package doc and also what makes the array total: a read always finds a
value, and a join can compare the two sides symbol by symbol.

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
	result: ir.Type, // what the arrow's `return` produces; VOID when nothing reads it
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
	// declared result, which the class may hold boxed (types.odin).
	result:   ir.Type,
	declared: ir.Type,
	returns:  check.Type_ID, // the declared result as check typed it; ERROR outside a function
	// By bind.Symbol_ID: the value of a local, or its box. NO_VALUE outside this function, for a
	// box whose scope has not been entered, and for a variable refused.
	locals:   []ir.Value_ID,
	refused:  []bool, // by bind.Symbol_ID: a local zero_locals reported
	loops:    [dynamic]Loop_Frame,
	inlines:  [dynamic]Inline_Frame, // the innermost last
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
	s.locals = make([]ir.Value_ID, len(s.bound.symbols), context.temp_allocator)
	slice.fill(s.locals, ir.NO_VALUE)
	s.refused = make([]bool, len(s.bound.symbols), context.temp_allocator)
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
				type = box_type(&s, type)
			}
			load := ir.Field_Load {
				cell  = cell,
				field = i32(i),
			}
			s.locals[symbol] = ir.emit(&s.fb, type, load, span)
		}
	}
	for param, i in params {
		symbol := s.bound.node_symbols[param]
		if symbol == bind.NO_SYMBOL || s.refused[symbol] {
			continue
		}
		value := unwrap(&s, ir.Value_ID(i), local_type(&s, symbol), span)
		bind_local(&s, symbol, value, span)
	}
	return s
}

// zero_locals takes a body to be the scopes whose nearest enclosing function is this one; the
// module scope is left out of the module init, because its bindings are globals of the program and
// not values of a function.
@(private)
zero_locals :: proc(s: ^Func_State, scope: bind.Scope_ID, span: source.Span) {
	for entry, i in s.bound.scopes {
		inner := bind.Scope_ID(i)
		if owning_function(s.bound, inner) != scope {
			continue
		}
		if scope == bind.MODULE_SCOPE && inner == bind.MODULE_SCOPE {
			continue
		}
		for symbol in entry.symbols {
			declared := s.bound.symbols[symbol]
			if declared.kind != .Let && declared.kind != .Const && declared.kind != .Param {
				continue
			}
			type, ok := ir_type(s.low, s.types, s.typed.node_types[declared.declaration])
			if !ok {
				node := s.tree.nodes[declared.declaration]
				text := construct_text(s.types, s.typed.node_types[declared.declaration])
				report(s.low, .Not_Lowered, node.span, text)
				s.refused[symbol] = true
				continue
			}
			// A box is made where its scope is entered, or where its variable is bound.
			if !s.low.closures[s.file].boxed[symbol] {
				s.locals[symbol] = zero_value(s, type, span)
			}
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
		if !is_variable || !facts.boxed[symbol] || s.refused[symbol] {
			continue
		}
		type := local_type(s, symbol)
		bind_local(s, symbol, zero_value(s, type, span), span)
	}
	for symbol in s.bound.scopes[scope].symbols {
		entry := s.bound.symbols[symbol]
		if entry.kind != .Function {
			continue
		}
		if facts.env_free[entry.declaration] && !facts.value_used[symbol] {
			continue // every call of it is direct
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

// read_local answers NO_VALUE for a local that was refused, or that holds nothing yet.
@(private)
read_local :: proc(s: ^Func_State, symbol: bind.Symbol_ID, span: source.Span) -> ir.Value_ID {
	value := s.locals[symbol]
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
		s.locals[symbol] = value
		return
	}
	if box := s.locals[symbol]; box != ir.NO_VALUE {
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
		s.locals[symbol] = value
		return
	}
	type := box_type(s, local_type(s, symbol))
	box := ir.emit(&s.fb, type, ir.Alloc{layout = type.layout}, span)
	store_slot(s, box, 0, value, span)
	s.locals[symbol] = box
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

// owning_function answers MODULE_SCOPE for a scope that no function encloses. MODULE_SCOPE is its
// own parent, so the walk always ends.
@(private)
owning_function :: proc(bound: ^bind.Bound_File, scope: bind.Scope_ID) -> bind.Scope_ID {
	current := scope
	for bound.scopes[current].kind != .Function && current != bind.MODULE_SCOPE {
		current = bound.scopes[current].parent
	}
	return current
}

// zero_value gives a string the empty cell rather than a null pointer, so no reader and no
// collector has to know about one. An object or an array has no empty value to take, so its
// binding starts as the null reference, which the collector skips and check never lets a program
// read before a value is stored.
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
		// The declaration that named one was reported already.
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

// open_join answers false for a block no edge reaches. Such a block cannot be entered, and takes an
// inert terminator so that the statements written after it still have a block to land in.
//
// A symbol one edge has no value for is left without one: it is a local of an inlined arrow, which
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
	for symbol in 0 ..< len(s.locals) {
		first := edges[0].values[symbol]
		same, missing := true, first == ir.NO_VALUE
		for edge in edges[1:] {
			same &&= edge.values[symbol] == first
			missing ||= edge.values[symbol] == ir.NO_VALUE
		}
		if missing {
			s.locals[symbol] = ir.NO_VALUE
			continue
		}
		if same {
			continue
		}
		merged := ir.phi(&s.fb, value_type(s, first), span)
		for edge in edges {
			ir.phi_incoming(&s.fb, merged, edge.block, edge.values[symbol])
		}
		s.locals[symbol] = merged
	}
	return true
}

// open_header cannot see its back edge yet, so it takes a phi for every symbol the loop assigns and
// the phis learn their edges through patch_header.
@(private)
open_header :: proc(
	s: ^Func_State,
	block: ir.Block_ID,
	assigned: []bind.Symbol_ID,
	from: Edge,
	span: source.Span,
) -> (
	phis: []ir.Value_ID,
) {
	ir.use_block(&s.fb, block)
	copy(s.locals, from.values)

	phis = make([]ir.Value_ID, len(assigned), context.temp_allocator)
	for symbol, i in assigned {
		entering := from.values[symbol]
		if entering == ir.NO_VALUE {
			phis[i] = ir.NO_VALUE
			continue
		}
		phis[i] = ir.phi(&s.fb, value_type(s, entering), span)
		ir.phi_incoming(&s.fb, phis[i], from.block, entering)
		s.locals[symbol] = phis[i]
	}
	return
}

@(private)
patch_header :: proc(s: ^Func_State, phis: []ir.Value_ID, assigned: []bind.Symbol_ID, back: Edge) {
	for symbol, i in assigned {
		if phis[i] != ir.NO_VALUE {
			ir.phi_incoming(&s.fb, phis[i], back.block, back.values[symbol])
		}
	}
}

// assigned_symbols lists the locals a subtree writes to, and `also`, in symbol order. It is the set a
// loop header needs a phi for; a symbol it names that the loop leaves alone only costs a dead phi.
@(private)
assigned_symbols :: proc(
	s: ^Func_State,
	root: ast.Node_ID,
	also: []bind.Symbol_ID = nil,
) -> []bind.Symbol_ID {
	found := make([dynamic]bind.Symbol_ID, 0, 8, context.temp_allocator)
	append(&found, ..also)
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
		symbol := s.bound.node_symbols[target]
		if symbol == bind.NO_SYMBOL || s.locals[symbol] == ir.NO_VALUE {
			continue
		}
		if !slice.contains(found[:], symbol) {
			append(&found, symbol)
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
