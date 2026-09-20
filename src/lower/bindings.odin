package lower

import "core:slice"

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

// Func_State is one IR function under construction.
Func_State :: struct {
	low:    ^Lowering,
	fb:     ir.Func_Builder,
	file:   source.File_ID,
	tree:   ^ast.File_AST,
	bound:  ^bind.Bound_File,
	typed:  ^check.Typed_File,
	types:  []check.Type,
	result: ir.Type, // what a `return` has to produce
	locals: []ir.Value_ID, // by bind.Symbol_ID; NO_VALUE outside this function, or poisoned
	loops:  [dynamic]Loop_Frame,
}

// begin_function opens a body and gives every local of it the zero of its type, parameters aside:
// those arrive as the values begin_func already emitted, in order.
@(private)
begin_function :: proc(
	low: ^Lowering,
	file: source.File_ID,
	id: ir.Func_ID,
	scope: bind.Scope_ID,
	params: []ast.Node_ID,
	result: ir.Type,
	span: source.Span,
) -> Func_State {
	s := Func_State {
		low    = low,
		fb     = ir.begin_func(&low.builder, id),
		file   = file,
		tree   = &low.prog.trees[file],
		bound  = &low.prog.bound[file],
		typed  = low.facts[file].typed,
		types  = low.facts[file].result.types,
		result = result,
		loops  = make([dynamic]Loop_Frame, context.temp_allocator),
	}
	s.locals = make([]ir.Value_ID, len(s.bound.symbols), context.temp_allocator)
	slice.fill(s.locals, ir.NO_VALUE)

	zero_locals(&s, scope, span)
	for param, i in params {
		symbol := s.bound.node_symbols[param]
		if symbol != bind.NO_SYMBOL {
			s.locals[symbol] = ir.Value_ID(i)
		}
	}
	return s
}

// zero_locals writes the zero of its type into every local of this body. A body is the scopes whose
// nearest enclosing function is this one; the module scope is left out of the module init, because
// its bindings are globals of the program and not values of a function.
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
			type, ok := ir_type(s.types, s.typed.node_types[declared.declaration])
			if !ok {
				node := s.tree.nodes[declared.declaration]
				text := construct_text(s.types, s.typed.node_types[declared.declaration])
				report(s.low, .Not_Lowered, node.span, text)
				continue
			}
			s.locals[symbol] = zero_value(s, type, span)
		}
	}
}

// owning_function is the nearest enclosing function scope, or MODULE_SCOPE for a scope that no
// function encloses. MODULE_SCOPE is its own parent, so the walk always ends.
@(private)
owning_function :: proc(bound: ^bind.Bound_File, scope: bind.Scope_ID) -> bind.Scope_ID {
	current := scope
	for bound.scopes[current].kind != .Function && current != bind.MODULE_SCOPE {
		current = bound.scopes[current].parent
	}
	return current
}

// zero_value is what a binding of this type holds before anything is written to it. A string takes
// the empty cell rather than a null pointer, so no reader and no collector has to know about one.
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
	case .Void, .Closure, .Ref:
		// Not in this slice; the declaration that named one was reported already.
		return ir.NO_VALUE
	}
	return ir.NO_VALUE
}

// here is the edge that leaves the block being built right now: where it is, and what the locals
// hold there.
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

// value_type is the type the builder recorded for a value.
@(private)
value_type :: proc(s: ^Func_State, value: ir.Value_ID) -> ir.Type {
	return s.fb.values[value].type
}

// open_join opens a block every edge jumps to and reconciles the locals: one phi per symbol the
// edges disagree about. A block no edge reaches cannot be entered, and takes an inert terminator so
// that the statements written after it still have a block to land in.
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
		if first == ir.NO_VALUE {
			continue
		}
		same := true
		for edge in edges[1:] {
			same &&= edge.values[symbol] == first
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

// open_header opens a loop header. Its back edge does not exist yet, so it takes a phi for every
// symbol the loop assigns and the phis learn their edges through patch_header.
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

// patch_header gives the header phis the values that arrive along the back edge.
@(private)
patch_header :: proc(s: ^Func_State, phis: []ir.Value_ID, assigned: []bind.Symbol_ID, back: Edge) {
	for symbol, i in assigned {
		if phis[i] != ir.NO_VALUE {
			ir.phi_incoming(&s.fb, phis[i], back.block, back.values[symbol])
		}
	}
}

// assigned_symbols lists the locals a subtree writes to, in symbol order. It is the set a loop
// header needs a phi for; a symbol it names that the loop leaves alone only costs a dead phi.
@(private)
assigned_symbols :: proc(s: ^Func_State, root: ast.Node_ID) -> []bind.Symbol_ID {
	found := make([dynamic]bind.Symbol_ID, 0, 8, context.temp_allocator)
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
