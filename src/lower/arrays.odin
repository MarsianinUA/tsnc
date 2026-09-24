package lower

import "../ast"
import "../bind"
import "../check"
import "../ir"
import "../source"

/*
Arrays: literals, elements, the methods of requirements 2.2, and `for...of`.

An array is a reference to a cell of fixed size that points at its unboxed elements (requirements
3.6). A literal is made at its final length and filled in place. Reading an element checks its
index; writing at the index that equals the length appends, as in Node, and a write past it fails
(requirements 3.8).

map, filter, forEach and reduce are loops built here, with the callback inlined into the body: an
arrow's parameters are bound to the element, its index and the array, its locals start from their
zero at every pass, and its `return` jumps to the end of the pass (Inline_Frame). The name of a
declared function is called directly instead. Node's rules for an array the callback changes hold:
the length is read once; forEach, filter and reduce stop where the array now ends, which is the same
as skipping the indices it no longer has, since only a callback changes the length; map fails there,
because Node would leave a hole an array of unboxed elements cannot hold. The other methods are rows
of the runtime.
*/

@(private)
lower_array_literal :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Array_Literal,
) -> ir.Value_ID {
	span := s.tree.nodes[id].span
	declared := s.typed.node_types[id]
	type, ok := ir_type(s.low, s.types, declared)
	element, element_ok := element_type(s, declared)
	if !ok || !element_ok {
		return later(s, span, construct_text(s.types, declared))
	}

	length := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = f64(len(node.elements))}, span)
	array := ir.emit(&s.fb, type, ir.New_Array{layout = type.layout, length = length}, span)
	complete := true
	for element_id, i in node.elements {
		value := coerce(s, lower_expression(s, element_id), element, s.tree.nodes[element_id].span)
		if value == ir.NO_VALUE {
			complete = false
			continue
		}
		// Every element shares the literal's two failure sites; none of them can fail.
		index := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = f64(i)}, span)
		store_checked(s, array, bounds_check(s, array, index, span), value, span)
	}
	return array if complete else ir.NO_VALUE
}

// element_type is the IR type of an element of an array of this TypeScript type. An element of
// `void`, which only map makes, holds undefined.
@(private)
element_type :: proc(s: ^Func_State, array_type: check.Type_ID) -> (type: ir.Type, ok: bool) {
	array := s.types[array_type].(check.Array) or_return
	type = ir_type(s.low, s.types, array.element) or_return
	return ir.TAGGED if type == ir.VOID else type, true
}

// receiver_element is the element type of the array in front of the dot of a method call.
@(private)
receiver_element :: proc(s: ^Func_State, node: ast.Call) -> (ir.Type, bool) {
	member := s.tree.nodes[node.callee].variant.(ast.Member)
	return element_type(s, s.typed.node_types[member.object])
}

@(private)
bounds_check :: proc(s: ^Func_State, array, index: ir.Value_ID, span: source.Span) -> ir.Value_ID {
	check := ir.Bounds_Check {
		array        = array,
		index        = index,
		not_integer  = fail_site(s.low, span, .Index_Not_Integer),
		out_of_range = fail_site(s.low, span, .Index_Out_Of_Range),
	}
	return ir.emit(&s.fb, ir.F64, check, span)
}

@(private)
store_checked :: proc(s: ^Func_State, array, checked, value: ir.Value_ID, span: source.Span) {
	kind := s.low.builder.layouts[value_type(s, array).layout].element
	if kind == .Ref || kind == .Tagged {
		store := ir.Element_Store_Ref {
			array = array,
			index = checked,
			value = value,
		}
		ir.emit(&s.fb, ir.VOID, store, span)
		return
	}
	store := ir.Element_Store {
		array = array,
		index = checked,
		value = value,
	}
	ir.emit(&s.fb, ir.VOID, store, span)
}

// Elements.

// element_place takes a string too, whose units a read gives out one at a time.
@(private)
element_place :: proc(
	s: ^Func_State,
	node: ast.Index,
	span: source.Span,
) -> (
	place: Place,
	ok: bool,
) {
	array := lower_expression(s, node.object)
	index := lower_expression(s, node.index)
	if array == ir.NO_VALUE || index == ir.NO_VALUE {
		return nil, false
	}
	if value_type(s, index) != ir.F64 {
		operand_not_lowered(s, index, span)
		return nil, false
	}
	type := value_type(s, array)
	if type == ir.STR {
		return Element_Place{array = array, index = index, type = ir.STR}, true
	}
	element, is_array := element_type(s, s.typed.node_types[node.object])
	if type.kind != .Ref || !is_array {
		later(s, span, "narrowing a union")
		return nil, false
	}
	return Element_Place{array = array, index = index, type = element}, true
}

@(private)
load_element :: proc(s: ^Func_State, place: ^Element_Place, span: source.Span) -> ir.Value_ID {
	if !place.checked {
		place.index = bounds_check(s, place.array, place.index, span)
		place.checked = true
	}
	if value_type(s, place.array) == ir.STR {
		call := ir.Call_Runtime {
			export = .String_At,
			args   = {place.array, place.index},
		}
		return ir.emit(&s.fb, ir.STR, call, span)
	}
	load := ir.Element_Load {
		array = place.array,
		index = place.index,
	}
	return ir.emit(&s.fb, place.type, load, span)
}

// store_element appends at an unchecked index equal to the length, as `a[a.length] = x` does in
// Node; any other index is checked. The test comes after the value, which JavaScript evaluates
// before it writes.
@(private)
store_element :: proc(
	s: ^Func_State,
	place: Element_Place,
	value: ir.Value_ID,
	span: source.Span,
) -> bool {
	if value_type(s, place.array) == ir.STR {
		later(s, span, "writing into a string")
		return false
	}
	stored := coerce(s, value, place.type, span)
	if stored == ir.NO_VALUE {
		return false
	}
	if place.checked {
		store_checked(s, place.array, place.index, stored, span)
		return true
	}

	length := ir.emit(&s.fb, ir.F64, ir.Length{value = place.array}, span)
	at_end := ir.Compare {
		op    = .Equal,
		left  = place.index,
		right = length,
	}
	appends := ir.emit(&s.fb, ir.BOOL, at_end, span)
	append_block := ir.add_block(&s.fb)
	write_block := ir.add_block(&s.fb)
	join := ir.add_block(&s.fb)
	branch := ir.Branch {
		condition  = appends,
		then_block = append_block,
		else_block = write_block,
	}
	ir.emit(&s.fb, ir.VOID, branch, span)

	ir.use_block(&s.fb, append_block)
	push(s, place.array, stored, span)
	appended := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)

	ir.use_block(&s.fb, write_block)
	store_checked(s, place.array, bounds_check(s, place.array, place.index, span), stored, span)
	written := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = join}, span)

	open_join(s, join, {appended, written}, span)
	return true
}

// push answers the new length. An element goes to the runtime boxed, whatever the array holds.
@(private)
push :: proc(s: ^Func_State, array, value: ir.Value_ID, span: source.Span) -> ir.Value_ID {
	boxed := coerce(s, value, ir.TAGGED, span)
	call := ir.Call_Runtime {
		export = .Array_Push,
		args   = {array, boxed},
	}
	return ir.emit(&s.fb, ir.F64, call, span)
}

// Methods.

// lower_push evaluates every argument before the first push, as Node evaluates the whole list, and
// answers the length after the last one.
@(private)
lower_push :: proc(
	s: ^Func_State,
	node: ast.Call,
	receiver: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	element, ok := receiver_element(s, node)
	if !ok {
		return ir.NO_VALUE
	}
	values := make([]ir.Value_ID, len(node.args), context.temp_allocator)
	complete := true
	for arg, i in node.args {
		values[i] = coerce(s, lower_expression(s, arg), element, s.tree.nodes[arg].span)
		complete &&= values[i] != ir.NO_VALUE
	}
	if !complete {
		return ir.NO_VALUE
	}
	length := ir.NO_VALUE
	for value in values {
		length = push(s, receiver, value, span)
	}
	if length == ir.NO_VALUE {
		length = ir.emit(&s.fb, ir.F64, ir.Length{value = receiver}, span)
	}
	return length
}

// lower_join passes the string constant "," for a separator the call leaves out.
@(private)
lower_join :: proc(
	s: ^Func_State,
	node: ast.Call,
	receiver: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	separator: ir.Value_ID
	if len(node.args) > 0 {
		separator = runtime_argument(s, node.args[0], .Ptr)
	} else {
		separator = string_constant(s, ",", span)
	}
	if separator == ir.NO_VALUE {
		return ir.NO_VALUE
	}
	call := ir.Call_Runtime {
		export = .Array_Join,
		args   = {receiver, separator},
	}
	return ir.emit(&s.fb, ir.STR, call, span)
}

// lower_sort sorts in place and answers the array. A comparator is a function value the runtime
// calls back, which needs the closure convention of T5.8.
@(private)
lower_sort :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Call,
	receiver: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	if len(node.args) > 0 {
		return later(s, span, "sorting with a comparator")
	}
	call := ir.Call_Runtime {
		export = .Array_Sort_Default,
		args   = {receiver},
	}
	return ir.emit(&s.fb, node_type(s, id), call, span)
}

@(private)
lower_for_each :: proc(
	s: ^Func_State,
	node: ast.Call,
	receiver: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	callback, ok := callback_of(s, node.args[0])
	element, element_ok := receiver_element(s, node)
	if !ok || !element_ok {
		return ir.NO_VALUE
	}
	length := ir.emit(&s.fb, ir.F64, ir.Length{value = receiver}, span)
	start := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
	loop := open_inline_loop(s, node.args[0], start, ir.NO_VALUE, span)
	leave_past_either_end(s, &loop, receiver, length, span)
	value := begin_pass(s, &loop, receiver, element, span)
	call_callback(s, callback, {value, loop.index, receiver}, span)
	close_inline_loop(s, &loop, ir.NO_VALUE, span)
	return ir.NO_VALUE
}

// lower_map makes the result at the length it reads once, and each pass reads its element through
// a check that fails where the callback shortened the array.
@(private)
lower_map :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Call,
	receiver: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	callback, ok := callback_of(s, node.args[0])
	element, element_ok := receiver_element(s, node)
	produced, produced_ok := element_type(s, s.typed.node_types[id])
	type := node_type(s, id)
	if !ok || !element_ok || !produced_ok {
		return ir.NO_VALUE
	}
	length := ir.emit(&s.fb, ir.F64, ir.Length{value = receiver}, span)
	out := ir.emit(&s.fb, type, ir.New_Array{layout = type.layout, length = length}, span)
	start := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
	loop := open_inline_loop(s, node.args[0], start, ir.NO_VALUE, span)
	leave_unless_before(s, &loop, length, span)
	value := begin_pass(s, &loop, receiver, element, span)
	mapped := call_callback(s, callback, {value, loop.index, receiver}, span)
	if callback.result == ir.VOID {
		mapped = ir.emit(&s.fb, ir.TAGGED, ir.Const_Undefined{}, span)
	}
	stored := coerce(s, mapped, produced, span)
	complete := stored != ir.NO_VALUE || terminated(s)
	if stored != ir.NO_VALUE {
		store_checked(s, out, bounds_check(s, out, loop.index, span), stored, span)
	}
	close_inline_loop(s, &loop, ir.NO_VALUE, span)
	return out if complete else ir.NO_VALUE
}

// lower_filter pushes each element the callback keeps onto an array that starts empty.
@(private)
lower_filter :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Call,
	receiver: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	callback, ok := callback_of(s, node.args[0])
	element, element_ok := receiver_element(s, node)
	type := node_type(s, id)
	if !ok || !element_ok || type.kind != .Ref {
		return ir.NO_VALUE
	}
	empty := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
	out := ir.emit(&s.fb, type, ir.New_Array{layout = type.layout, length = empty}, span)
	length := ir.emit(&s.fb, ir.F64, ir.Length{value = receiver}, span)
	loop := open_inline_loop(s, node.args[0], empty, ir.NO_VALUE, span)
	leave_past_either_end(s, &loop, receiver, length, span)
	value := begin_pass(s, &loop, receiver, element, span)
	keep := truthy(s, call_callback(s, callback, {value, loop.index, receiver}, span), span)
	complete := keep != ir.NO_VALUE || terminated(s)
	if keep != ir.NO_VALUE {
		kept := ir.add_block(&s.fb)
		after := ir.add_block(&s.fb)
		skipped := here(s)
		branch := ir.Branch {
			condition  = keep,
			then_block = kept,
			else_block = after,
		}
		ir.emit(&s.fb, ir.VOID, branch, span)
		ir.use_block(&s.fb, kept)
		push(s, out, value, span)
		pushed := here(s)
		ir.emit(&s.fb, ir.VOID, ir.Jump{target = after}, span)
		open_join(s, after, {skipped, pushed}, span)
	}
	close_inline_loop(s, &loop, ir.NO_VALUE, span)
	return out if complete else ir.NO_VALUE
}

// lower_reduce without an initial value starts from the first element and fails on an empty array
// with Node's message. With one, the value is evaluated before the length is read, as the arguments
// of a call come before its body.
@(private)
lower_reduce :: proc(
	s: ^Func_State,
	id: ast.Node_ID,
	node: ast.Call,
	receiver: ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	callback, ok := callback_of(s, node.args[0])
	element, element_ok := receiver_element(s, node)
	result := node_type(s, id)
	if !ok || !element_ok || result == ir.VOID {
		return ir.NO_VALUE
	}

	start, first: ir.Value_ID
	if len(node.args) > 1 {
		first = coerce(s, lower_expression(s, node.args[1]), result, span)
		if first == ir.NO_VALUE {
			return ir.NO_VALUE
		}
		start = ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
	}
	length := ir.emit(&s.fb, ir.F64, ir.Length{value = receiver}, span)
	if len(node.args) == 1 {
		zero := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
		test := ir.Compare {
			op    = .Equal,
			left  = length,
			right = zero,
		}
		empty := ir.emit(&s.fb, ir.BOOL, test, span)
		failed := ir.add_block(&s.fb)
		started := ir.add_block(&s.fb)
		branch := ir.Branch {
			condition  = empty,
			then_block = failed,
			else_block = started,
		}
		ir.emit(&s.fb, ir.VOID, branch, span)
		ir.use_block(&s.fb, failed)
		ir.emit(
			&s.fb,
			ir.VOID,
			ir.Fail{site = fail_site(s.low, span, .Reduce_Of_Empty_Array)},
			span,
		)
		ir.use_block(&s.fb, started)
		load := ir.Element_Load {
			array = receiver,
			index = bounds_check(s, receiver, zero, span),
		}
		first = coerce(s, ir.emit(&s.fb, element, load, span), result, span)
		if first == ir.NO_VALUE {
			return ir.NO_VALUE
		}
		start = ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 1}, span)
	}

	loop := open_inline_loop(s, node.args[0], start, first, span)
	leave_past_either_end(s, &loop, receiver, length, span)
	value := begin_pass(s, &loop, receiver, element, span)
	args := [?]ir.Value_ID{loop.accumulator, value, loop.index, receiver}
	next := coerce(s, call_callback(s, callback, args[:], span), result, span)
	close_inline_loop(s, &loop, next, span)
	return loop.accumulator
}

// Inline loops.

// Inline_Loop is the loop the four methods share. The header holds the phis of the locals the
// callback writes, then the index and, for reduce, the accumulator. next is the index of the next
// pass, computed at the top of the body, where it dominates the back edge: nothing in an inlined
// callback can jump to the end of the pass but its own `return`, which joins inside the body.
@(private)
Inline_Loop :: struct {
	header:      ir.Block_ID,
	exit:        ir.Block_ID,
	assigned:    []bind.Symbol_ID,
	phis:        []ir.Value_ID,
	index:       ir.Value_ID,
	accumulator: ir.Value_ID, // NO_VALUE but in reduce
	next:        ir.Value_ID,
	leaving:     [dynamic]Edge, // the edges into the exit
}

@(private)
open_inline_loop :: proc(
	s: ^Func_State,
	callback: ast.Node_ID,
	start, accumulator: ir.Value_ID,
	span: source.Span,
) -> Inline_Loop {
	loop := Inline_Loop {
		header      = ir.add_block(&s.fb),
		exit        = ir.add_block(&s.fb),
		assigned    = assigned_symbols(s, callback),
		accumulator = ir.NO_VALUE,
		leaving     = make([dynamic]Edge, 0, 2, context.temp_allocator),
	}
	from := here(s)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = loop.header}, span)
	loop.phis = open_header(s, loop.header, loop.assigned, from, span)
	loop.index = ir.phi(&s.fb, ir.F64, span)
	ir.phi_incoming(&s.fb, loop.index, from.block, start)
	if accumulator != ir.NO_VALUE {
		loop.accumulator = ir.phi(&s.fb, value_type(s, accumulator), span)
		ir.phi_incoming(&s.fb, loop.accumulator, from.block, accumulator)
	}
	return loop
}

// leave_past_either_end leaves the loop at the length read before the first pass or at the
// length the array has now, whichever comes first: forEach, filter and reduce stop where a
// callback shortened the array.
@(private)
leave_past_either_end :: proc(
	s: ^Func_State,
	loop: ^Inline_Loop,
	array, length: ir.Value_ID,
	span: source.Span,
) {
	leave_unless_before(s, loop, length, span)
	leave_unless_before(s, loop, ir.emit(&s.fb, ir.F64, ir.Length{value = array}, span), span)
}

// leave_unless_before goes on in a block of its own while the index is below `bound`, and leaves
// the loop otherwise.
@(private)
leave_unless_before :: proc(
	s: ^Func_State,
	loop: ^Inline_Loop,
	bound: ir.Value_ID,
	span: source.Span,
) {
	test := ir.Compare {
		op    = .Less,
		left  = loop.index,
		right = bound,
	}
	below := ir.emit(&s.fb, ir.BOOL, test, span)
	passing := ir.add_block(&s.fb)
	append(&loop.leaving, here(s))
	branch := ir.Branch {
		condition  = below,
		then_block = passing,
		else_block = loop.exit,
	}
	ir.emit(&s.fb, ir.VOID, branch, span)
	ir.use_block(&s.fb, passing)
}

// begin_pass sets the index of the next pass and answers the element of this one.
@(private)
begin_pass :: proc(
	s: ^Func_State,
	loop: ^Inline_Loop,
	array: ir.Value_ID,
	element: ir.Type,
	span: source.Span,
) -> ir.Value_ID {
	one := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 1}, span)
	loop.next = ir.emit(&s.fb, ir.F64, ir.Binary{op = .Add, left = loop.index, right = one}, span)
	load := ir.Element_Load {
		array = array,
		index = bounds_check(s, array, loop.index, span),
	}
	return ir.emit(&s.fb, element, load, span)
}

// close_inline_loop takes the back edge unless the pass cannot end, and leaves the builder in the
// exit. A poisoned accumulator keeps its old value, so the IR stays whole; it was reported.
@(private)
close_inline_loop :: proc(
	s: ^Func_State,
	loop: ^Inline_Loop,
	accumulator: ir.Value_ID,
	span: source.Span,
) {
	if !terminated(s) {
		back := here(s)
		ir.emit(&s.fb, ir.VOID, ir.Jump{target = loop.header}, span)
		patch_header(s, loop.phis, loop.assigned, back)
		ir.phi_incoming(&s.fb, loop.index, back.block, loop.next)
		if loop.accumulator != ir.NO_VALUE {
			next := accumulator if accumulator != ir.NO_VALUE else loop.accumulator
			ir.phi_incoming(&s.fb, loop.accumulator, back.block, next)
		}
	}
	open_join(s, loop.exit, loop.leaving[:], span)
}

// Callbacks.

// Callback is what an array method calls for each element: an arrow written in the call, inlined,
// or the name of a declared function, called directly.
@(private)
Callback :: struct {
	arrow:  ast.Node_ID, // NO_NODE for a function
	func:   ir.Func_ID,
	result: ir.Type, // VOID when the callback returns nothing
}

// callback_of leaves any other function value to lower_expression, which reports it where it was
// made, since calling one needs the closures of T5.8.
@(private)
callback_of :: proc(s: ^Func_State, id: ast.Node_ID) -> (callback: Callback, ok: bool) {
	span := s.tree.nodes[id].span
	#partial switch _ in s.tree.nodes[id].variant {
	case ast.Arrow:
		signature, is_function := s.types[s.typed.node_types[id]].(check.Function)
		if !is_function {
			return {}, false
		}
		result, representable := ir_type(s.low, s.types, signature.result)
		if !representable {
			later(s, span, construct_text(s.types, signature.result))
			return {}, false
		}
		return {arrow = id, result = result}, true
	case ast.Ident, ast.Member:
		ref := s.typed.node_symbols[id]
		if ref.symbol != bind.NO_SYMBOL {
			declared := s.low.prog.bound[ref.file].symbols[ref.symbol]
			if func, found := s.low.funcs[{ref.file, declared.declaration}]; found {
				result := s.low.builder.funcs[func].result
				return {arrow = ast.NO_NODE, func = func, result = result}, true
			}
			if declared.kind == .Function {
				// The declaration was refused where it stands; a use of it says nothing more.
				return {}, false
			}
		}
	}
	if lower_expression(s, id) != ir.NO_VALUE {
		later(s, span, "function values")
	}
	return {}, false
}

// call_callback passes as many of the arguments as the callback takes.
@(private)
call_callback :: proc(
	s: ^Func_State,
	callback: Callback,
	args: []ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	if callback.arrow == ast.NO_NODE {
		count := min(len(args), len(s.low.builder.funcs[callback.func].params))
		return call_function(s, callback.func, args[:count], span)
	}
	return inline_arrow(s, callback, args, span)
}

// inline_arrow lowers the arrow's body in place. Its locals take their zero at every pass, as a
// new call's would. `break` and `continue` cannot leave an arrow, so the loops around the call are
// no targets inside it, and its `return` goes to the join of this frame.
@(private)
inline_arrow :: proc(
	s: ^Func_State,
	callback: Callback,
	args: []ir.Value_ID,
	span: source.Span,
) -> ir.Value_ID {
	arrow := s.tree.nodes[callback.arrow].variant.(ast.Arrow)
	zero_locals(s, s.bound.node_scopes[callback.arrow], span)
	for param, i in arrow.params {
		symbol := s.bound.node_symbols[param]
		if i >= len(args) || symbol == bind.NO_SYMBOL || s.locals[symbol] == ir.NO_VALUE {
			continue
		}
		bound := coerce(s, args[i], value_type(s, s.locals[symbol]), span)
		if bound != ir.NO_VALUE {
			s.locals[symbol] = bound
		}
	}

	outer_loops := s.loops
	s.loops = make([dynamic]Loop_Frame, context.temp_allocator)
	frame := Inline_Frame {
		join   = ir.add_block(&s.fb),
		result = callback.result,
		edges  = make([dynamic]Edge, 0, 2, context.temp_allocator),
		values = make([dynamic]ir.Value_ID, 0, 2, context.temp_allocator),
	}
	append(&s.inlines, frame)

	body := arrow.body
	_, is_block := s.tree.nodes[body].variant.(ast.Block)
	switch {
	case is_block:
		lower_statement(s, body)
		if !terminated(s) {
			// Running off the end returns undefined.
			leave_arrow(s, undefined_of(s, callback.result, span), span)
		}
	case s.typed.node_types[body] == check.NEVER:
		lower_effect(s, body)
		if !terminated(s) {
			ir.emit(&s.fb, ir.VOID, ir.Unreachable{}, span)
		}
	case callback.result == ir.VOID:
		lower_effect(s, body)
		leave_arrow(s, ir.NO_VALUE, span)
	case:
		leave_arrow(s, coerce(s, lower_expression(s, body), callback.result, span), span)
	}

	frame = pop(&s.inlines)
	s.loops = outer_loops
	return join_values(s, frame.join, frame.edges[:], frame.values[:], frame.result, span)
}

// leave_arrow is a `return` of the innermost inlined arrow.
@(private)
leave_arrow :: proc(s: ^Func_State, value: ir.Value_ID, span: source.Span) {
	frame := &s.inlines[len(s.inlines) - 1]
	append(&frame.edges, here(s))
	append(&frame.values, value)
	ir.emit(&s.fb, ir.VOID, ir.Jump{target = frame.join}, span)
}

// undefined_of is what a bare `return` gives a caller that reads a value of this type.
@(private)
undefined_of :: proc(s: ^Func_State, type: ir.Type, span: source.Span) -> ir.Value_ID {
	if type == ir.TAGGED {
		return ir.emit(&s.fb, ir.TAGGED, ir.Const_Undefined{}, span)
	}
	return ir.NO_VALUE
}

// for...of

// lower_for_of reads the length again before every step, as the iterator does, so a body that
// pushes is walked to the new end. A string is walked by code point: a step takes a surrogate pair
// whole and moves the index by the length of what it took.
@(private)
lower_for_of :: proc(s: ^Func_State, id: ast.Node_ID, node: ast.For_Of, span: source.Span) {
	iterable := lower_expression(s, node.iterable)
	declaration := s.tree.nodes[node.declaration].variant.(ast.Var_Decl)
	symbol := s.bound.node_symbols[declaration.declarators[0]]
	element, is_array := element_type(s, s.typed.node_types[node.iterable])
	is_string := iterable != ir.NO_VALUE && value_type(s, iterable) == ir.STR
	is_array &&= iterable != ir.NO_VALUE && value_type(s, iterable).kind == .Ref
	if iterable != ir.NO_VALUE && !is_string && !is_array {
		later(s, span, "narrowing a union")
	}
	if !is_string && !is_array || symbol == bind.NO_SYMBOL || s.locals[symbol] == ir.NO_VALUE {
		// Whatever is wrong was reported; the body is still walked for what it holds.
		lower_statement(s, node.body)
		return
	}

	assigned := assigned_symbols(s, id)
	blocks := open_loop(s)
	start := ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 0}, span)
	entry := s.fb.current
	phis := enter_loop(s, blocks, assigned, span)
	index := ir.phi(&s.fb, ir.F64, span)
	ir.phi_incoming(&s.fb, index, entry, start)
	length := ir.emit(&s.fb, ir.F64, ir.Length{value = iterable}, span)
	more := ir.emit(&s.fb, ir.BOOL, ir.Compare{op = .Less, left = index, right = length}, span)
	leaving := here(s)
	branch := ir.Branch {
		condition  = more,
		then_block = blocks.body,
		else_block = blocks.exit,
	}
	ir.emit(&s.fb, ir.VOID, branch, span)

	ir.use_block(&s.fb, blocks.body)
	checked := bounds_check(s, iterable, index, span)
	step, piece: ir.Value_ID
	if is_string {
		call := ir.Call_Runtime {
			export = .String_Code_Point_At,
			args   = {iterable, checked},
		}
		piece = ir.emit(&s.fb, ir.STR, call, span)
		step = ir.emit(&s.fb, ir.F64, ir.Length{value = piece}, span)
	} else {
		load := ir.Element_Load {
			array = iterable,
			index = checked,
		}
		piece = ir.emit(&s.fb, element, load, span)
		step = ir.emit(&s.fb, ir.F64, ir.Const_Number{value = 1}, span)
	}
	next := ir.emit(&s.fb, ir.F64, ir.Binary{op = .Add, left = index, right = step}, span)
	if bound := coerce(s, piece, value_type(s, s.locals[symbol]), span); bound != ir.NO_VALUE {
		s.locals[symbol] = bound
	}

	push_frame(s, blocks.latch, blocks.exit)
	lower_statement(s, node.body)
	frame := pop(&s.loops)
	if open_latch(s, blocks.latch, frame, span) {
		back := here(s)
		ir.emit(&s.fb, ir.VOID, ir.Jump{target = blocks.header}, span)
		patch_header(s, phis, assigned, back)
		ir.phi_incoming(&s.fb, index, back.block, next)
	}
	leave_loop(s, blocks.exit, leaving, frame, span)
}
