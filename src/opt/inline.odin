#+private
package opt

import "base:runtime"
import "core:slice"

import "../ir"

/*
Inlining runs before the other passes, so that escape and split see the cell a small function
returns stay in its caller. A function is inlined where it is small, has no loop and does not call
itself. Callees go before their callers, so a body is copied once it is final, and a cycle of calls
is cut where the walk closes it: each body is inlined once, so the code grows by at most
INLINE_LIMIT per call site.

The copy keeps the spans and the failure sites of the callee, so a runtime error names the line it
named before.
*/

INLINE_LIMIT :: 40 // instructions in the blocks of a callee whose own calls were inlined

inline_calls :: proc(p: ^ir.Program_IR, allocator: runtime.Allocator) {
	// main and the module inits run once: inlining them gains nothing.
	entry := make([]bool, len(p.funcs), context.temp_allocator)
	entry[p.main] = true
	for id in p.init_order {
		entry[id] = true
	}
	small := make([]bool, len(p.funcs), context.temp_allocator)
	for id in callees_first(p^) {
		if calls_small(p.funcs[id], small) {
			expand(p, id, small, allocator)
		}
		small[id] = !entry[id] && is_small(p.funcs[id], id)
	}
}

// callees_first carries its own stack, as ir's walk over blocks does.
@(private = "file")
callees_first :: proc(p: ir.Program_IR) -> []ir.Func_ID {
	Frame :: struct {
		func:  ir.Func_ID,
		calls: []ir.Func_ID,
		next:  int,
	}

	order := make([dynamic]ir.Func_ID, 0, len(p.funcs), context.temp_allocator)
	visited := make([]bool, len(p.funcs), context.temp_allocator)
	stack := make([dynamic]Frame, context.temp_allocator)
	for root in 0 ..< len(p.funcs) {
		if visited[root] {
			continue
		}
		visited[root] = true
		append(&stack, Frame{func = ir.Func_ID(root), calls = direct_calls(p.funcs[root])})
		for len(stack) > 0 {
			top := &stack[len(stack) - 1]
			if top.next == len(top.calls) {
				append(&order, top.func)
				pop(&stack)
				continue
			}
			callee := top.calls[top.next]
			top.next += 1
			if !visited[callee] {
				visited[callee] = true
				append(&stack, Frame{func = callee, calls = direct_calls(p.funcs[callee])})
			}
		}
	}
	return order[:]
}

@(private = "file")
direct_calls :: proc(func: ir.Func) -> []ir.Func_ID {
	calls := make([dynamic]ir.Func_ID, context.temp_allocator)
	for block in func.blocks {
		for value in block.instructions {
			if call, is_call := func.values[value].variant.(ir.Call); is_call {
				append(&calls, call.func)
			}
		}
	}
	return calls[:]
}

@(private = "file")
calls_small :: proc(func: ir.Func, small: []bool) -> bool {
	for block in func.blocks {
		if block_calls_small(func, block, small) {
			return true
		}
	}
	return false
}

@(private = "file")
block_calls_small :: proc(func: ir.Func, block: ir.Block, small: []bool) -> bool {
	for value in block.instructions {
		if call, is_call := func.values[value].variant.(ir.Call); is_call && small[call.func] {
			return true
		}
	}
	return false
}

@(private = "file")
is_small :: proc(func: ir.Func, id: ir.Func_ID) -> bool {
	size := 0
	returns := false
	for block in func.blocks {
		size += len(block.instructions)
		for value in block.instructions {
			#partial switch v in func.values[value].variant {
			case ir.Return:
				returns = true
			case ir.Call:
				if v.func == id {
					return false
				}
			}
		}
	}
	if size > INLINE_LIMIT || !returns {
		return false
	}
	flow := ir.make_flow(func, context.temp_allocator)
	for block in flow.order {
		for pred in flow.preds[block] {
			if flow.rank[pred] >= flow.rank[block] {
				return false
			}
		}
	}
	return true
}

// Expansion rebuilds one caller. Its blocks keep their ids; the rest of a block split at a call goes
// on in a block appended after the copy of the callee.
@(private = "file")
Expansion :: struct {
	p:         ^ir.Program_IR,
	values:    [dynamic]ir.Instruction,
	blocks:    [dynamic]ir.Block,
	result:    []ir.Value_ID, // by the Value_ID of an inlined call: what stands for it now
	fields:    [dynamic]^ir.Value_ID,
	allocator: runtime.Allocator,
}

@(private = "file")
expand :: proc(p: ^ir.Program_IR, id: ir.Func_ID, small: []bool, allocator: runtime.Allocator) {
	caller := &p.funcs[id]
	e := Expansion {
		p         = p,
		values    = make([dynamic]ir.Instruction, 0, 2 * len(caller.values), allocator),
		blocks    = make([dynamic]ir.Block, 0, 2 * len(caller.blocks), allocator),
		result    = make([]ir.Value_ID, len(caller.values), context.temp_allocator),
		fields    = make([dynamic]^ir.Value_ID, context.temp_allocator),
		allocator = allocator,
	}
	append(&e.values, ..caller.values)
	append(&e.blocks, ..caller.blocks)
	slice.fill(e.result, ir.NO_VALUE)

	// exit[b] is the block that ends with the terminator block b had.
	exit := make([]ir.Block_ID, len(caller.blocks), context.temp_allocator)
	for block, b in caller.blocks {
		exit[b] = ir.Block_ID(b)
		if !block_calls_small(caller^, block, small) {
			continue
		}
		list := make([dynamic]ir.Value_ID, allocator)
		for value in block.instructions {
			call, is_call := caller.values[value].variant.(ir.Call)
			if !is_call || !small[call.func] {
				append(&list, value)
				continue
			}
			list, exit[b] = inline_call(&e, exit[b], list, value, call)
		}
		e.blocks[exit[b]].instructions = list[:]
	}

	// Blocks go in index order, not dominance order, so a copy may take as an argument a call that
	// is inlined only after it.
	for &instruction, v in e.values {
		ir.operands(&instruction.variant, &e.fields)
		for field in e.fields {
			field^ = resolved(e.result, field^)
		}
		phi, is_phi := &instruction.variant.(ir.Phi)
		if is_phi && v < len(caller.values) {
			for &edge in phi.incoming {
				edge.block = exit[edge.block]
			}
		}
	}
	caller.values = e.values[:]
	caller.blocks = e.blocks[:]
}

// inline_call ends the block being built with a jump into a copy of the callee, and answers the
// list of the block where the caller goes on.
@(private = "file")
inline_call :: proc(
	e: ^Expansion,
	block: ir.Block_ID,
	list: [dynamic]ir.Value_ID,
	value: ir.Value_ID,
	call: ir.Call,
) -> (
	rest: [dynamic]ir.Value_ID,
	rest_block: ir.Block_ID,
) {
	callee := e.p.funcs[call.func]
	span := e.values[value].span
	first := ir.Block_ID(len(e.blocks))
	rest_block = first + ir.Block_ID(len(callee.blocks))

	list := list
	append(&list, add_value(e, {span = span, variant = ir.Jump{target = first}}))
	e.blocks[block].instructions = list[:]

	// A parameter is its argument. An argument whose type only fits the parameter's, a present
	// reference for one that may be null, comes through a phi of the parameter's type.
	copies := make([]ir.Value_ID, len(callee.values), context.temp_allocator)
	slice.fill(copies, ir.NO_VALUE)
	widened := make([dynamic]ir.Value_ID, context.temp_allocator)
	for callee_block in callee.blocks {
		for v in callee_block.instructions {
			param, is_param := callee.values[v].variant.(ir.Param)
			if !is_param {
				copies[v] = add_value(e, callee.values[v])
				continue
			}
			arg := call.args[param.index]
			type := callee.params[param.index]
			if e.values[arg].type == type {
				copies[v] = arg
				continue
			}
			incoming := slice.clone([]ir.Incoming{{block = block, value = arg}}, e.allocator)
			copies[v] = add_value(
				e,
				{span = span, type = type, variant = ir.Phi{incoming = incoming}},
			)
			append(&widened, copies[v])
		}
	}

	returns := make([dynamic]ir.Incoming, e.allocator)
	for callee_block, b in callee.blocks {
		copied := make([dynamic]ir.Value_ID, 0, len(callee_block.instructions), e.allocator)
		if b == int(ir.ENTRY) {
			append(&copied, ..widened[:])
		}
		for v in callee_block.instructions {
			if _, is_param := callee.values[v].variant.(ir.Param); is_param {
				continue
			}
			instruction := &e.values[copies[v]]
			own_lists(&instruction.variant, e.allocator)
			ir.operands(&instruction.variant, &e.fields)
			for field in e.fields {
				assert(copies[field^] != ir.NO_VALUE, "an operand of a callee is in no block")
				field^ = copies[field^]
			}
			#partial switch &w in instruction.variant {
			case ir.Jump:
				w.target += first
			case ir.Branch:
				w.then_block += first
				w.else_block += first
			case ir.Phi:
				for &edge in w.incoming {
					edge.block += first
				}
			case ir.Return:
				append(&returns, ir.Incoming{block = first + ir.Block_ID(b), value = w.value})
				instruction.variant = ir.Jump {
					target = rest_block,
				}
			}
			append(&copied, copies[v])
		}
		append(&e.blocks, ir.Block{instructions = copied[:]})
	}
	append(&e.blocks, ir.Block{})

	rest = make([dynamic]ir.Value_ID, e.allocator)
	if callee.result == ir.VOID {
		return
	}
	only := returns[0].value
	if len(returns) == 1 && e.values[only].type == callee.result {
		e.result[value] = only
		return
	}
	phi := ir.Instruction {
		span = span,
		type = callee.result,
		variant = ir.Phi{incoming = returns[:]},
	}
	e.result[value] = add_value(e, phi)
	append(&rest, e.result[value])
	return
}

@(private = "file")
add_value :: proc(e: ^Expansion, instruction: ir.Instruction) -> ir.Value_ID {
	append(&e.values, instruction)
	return ir.Value_ID(len(e.values) - 1)
}

// resolved follows a table of values that stand for others: an inlined call may stand for another
// one, as when a callee returns its parameter, and a split field read for another read.
resolved :: proc(stands: []ir.Value_ID, value: ir.Value_ID) -> ir.Value_ID {
	value := value
	for int(value) < len(stands) && stands[value] != ir.NO_VALUE {
		value = stands[value]
	}
	return value
}

// own_lists gives a copied instruction lists of its own, so that renaming its operands leaves the
// callee as it was.
@(private = "file")
own_lists :: proc(variant: ^ir.Variant, allocator: runtime.Allocator) {
	#partial switch &v in variant {
	case ir.Phi:
		v.incoming = slice.clone(v.incoming, allocator)
	case ir.Call:
		v.args = slice.clone(v.args, allocator)
	case ir.Call_Closure:
		v.args = slice.clone(v.args, allocator)
	case ir.Call_Runtime:
		v.args = slice.clone(v.args, allocator)
	case ir.Intrinsic:
		v.args = slice.clone(v.args, allocator)
	}
}
