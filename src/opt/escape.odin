#+private
package opt

import "../ir"

/*
Escape analysis: a cell goes on the stack of its function when every use of every value that may
point to it keeps it in this frame (kept). LLVM then splits it into registers where it can; opt has
no scalar replacement of its own. Points-to is per function and ignores the order of instructions.

The callees' side comes from summaries, one per environment and per reference parameter: the Env and
the Param of a function stand for cells of the caller's. A summary starts out not leaking and only
ever starts to, so the fixpoint over all functions is the least one; each function's own cells start
on the stack and fall back to the heap until nothing moves.

A function gets at most STACK_BUDGET bytes of stack cells, since a recursive one takes them again in
every frame; the cells after that stay on the heap.
*/

STACK_BUDGET :: 256

place_cells :: proc(p: ^ir.Program_IR, shapes: []Shape) {
	e := Escape {
		frames = make([]Frame, len(p.funcs), context.temp_allocator),
		env    = make([]bool, len(p.funcs), context.temp_allocator),
		params = make([][]bool, len(p.funcs), context.temp_allocator),
		fields = make([dynamic]^ir.Value_ID, context.temp_allocator),
	}
	for func, id in p.funcs {
		e.params[id] = make([]bool, len(func.params), context.temp_allocator)
		e.frames[id] = prepare_frame(p^, &p.funcs[id], shapes[id])
	}
	for leaked := true; leaked; {
		leaked = false
		for id in 0 ..< len(p.funcs) {
			decide(&e, &e.frames[id])
			leaked |= record_leaks(&e, ir.Func_ID(id))
		}
	}
	for &frame in e.frames {
		for site in frame.sites {
			if site.stack && site.pseudo == .None {
				ir.cell_place(&frame.func.values[site.value].variant)^ = .Stack
			}
		}
	}
}

@(private = "file")
Escape :: struct {
	frames: []Frame, // by Func_ID
	env:    []bool, // by Func_ID: the function may let its environment out
	params: [][]bool, // by Func_ID, then parameter: the function may let that argument out
	fields: [dynamic]^ir.Value_ID, // scratch of check_uses
}

@(private = "file")
Frame :: struct {
	func:    ^ir.Func,
	sites:   [dynamic]Site,
	points:  [][dynamic]i32, // by Value_ID: the sites the value may point to
	places:  []ir.Place, // by Value_ID
	loop:    []ir.Block_ID, // by Block_ID: the header of its innermost loop, NO_BLOCK outside one
	outer:   []ir.Block_ID, // by the Block_ID of a header: the header of the loop around it
	// A retreating edge that is no back edge makes loops this analysis cannot nest, so every cell
	// of such a function stays on the heap.
	tangled: bool,
}

@(private = "file")
Pseudo :: enum u8 {
	None, // a cell the function makes
	Env,
	Param,
}

@(private = "file")
Site :: struct {
	value:  ir.Value_ID,
	size:   int, // bytes of stack the cell takes, 16-byte aligned
	stack:  bool, // still on the stack; for a pseudo site, not let out yet
	pseudo: Pseudo,
	param:  i32,
}

@(private = "file")
prepare_frame :: proc(p: ir.Program_IR, func: ^ir.Func, shape: Shape) -> Frame {
	count := len(func.values)
	frame := Frame {
		func   = func,
		sites  = make([dynamic]Site, context.temp_allocator),
		points = make([][dynamic]i32, count, context.temp_allocator),
		places = shape.places,
		loop   = make([]ir.Block_ID, len(func.blocks), context.temp_allocator),
		outer  = make([]ir.Block_ID, len(func.blocks), context.temp_allocator),
	}
	find_loops(&frame, shape)

	// Every cell points to itself.
	for instruction, id in func.values {
		value := ir.Value_ID(id)
		site := Site {
			value = value,
			stack = true,
		}
		#partial switch v in instruction.variant {
		case ir.Alloc, ir.New_Array, ir.Make_Closure:
			size, fits := ir.cell_size(p, func^, value)
			if !fits {
				continue
			}
			site.size = size
		case ir.Env:
			site.pseudo = .Env
		case ir.Param:
			kind := instruction.type.kind
			if kind != .Ref && kind != .Closure {
				continue
			}
			site.pseudo, site.param = .Param, v.index
		case:
			continue
		}
		// A cell that never runs stays as lower left it.
		if frame.places[value].block == ir.NO_BLOCK {
			continue
		}
		site.size = (site.size + 15) &~ 15
		add_point(&frame.points[value], i32(len(frame.sites)))
		append(&frame.sites, site)
	}

	// What else may point to them, until nothing grows.
	stored := make([][dynamic]i32, len(frame.sites), context.temp_allocator)
	for grew := true; grew; {
		grew = false
		for instruction, id in func.values {
			#partial switch v in instruction.variant {
			case ir.Non_Null:
				grew |= add_points(&frame.points[id], frame.points[v.value][:])
			case ir.Phi:
				for edge in v.incoming {
					grew |= add_points(&frame.points[id], frame.points[edge.value][:])
				}
			case ir.Field_Store_Ref:
				for site in frame.points[v.cell] {
					grew |= add_points(&stored[site], frame.points[v.value][:])
				}
			case ir.Field_Load:
				for site in frame.points[v.cell] {
					grew |= add_points(&frame.points[id], stored[site][:])
					// The caller may have stored its own cell there, which goes where this goes.
					kind := instruction.type.kind
					if frame.sites[site].pseudo != .None && (kind == .Ref || kind == .Closure) {
						grew |= add_point(&frame.points[id], site)
					}
				}
			}
		}
	}
	return frame
}

// find_loops visits headers in reverse post-order, outer before inner, so an inner loop's blocks
// end up with its own header.
@(private = "file")
find_loops :: proc(frame: ^Frame, shape: Shape) {
	for &block in frame.loop {
		block = ir.NO_BLOCK
	}
	for &block in frame.outer {
		block = ir.NO_BLOCK
	}
	flow := shape.flow
	for header in flow.order {
		if !shape.header[header] {
			continue
		}
		latches := make([dynamic]ir.Block_ID, context.temp_allocator)
		for pred in flow.preds[header] {
			if flow.rank[pred] < flow.rank[header] {
				continue
			}
			if !ir.dominates(flow, header, pred) {
				frame.tangled = true
				return
			}
			append(&latches, pred)
		}
		frame.outer[header] = frame.loop[header]
		body := make([]bool, len(frame.loop), context.temp_allocator)
		body[header] = true
		for len(latches) > 0 {
			block := pop(&latches)
			if body[block] {
				continue
			}
			body[block] = true
			append(&latches, ..flow.preds[block])
		}
		for inside, block in body {
			if inside {
				frame.loop[block] = header
			}
		}
	}
}

// decide runs again after a budget cut: a cell moved to the heap lets out what it holds.
@(private = "file")
decide :: proc(e: ^Escape, frame: ^Frame) {
	for &site in frame.sites {
		site.stack = !frame.tangled
	}
	for {
		for moved := true; moved; {
			moved = false
			for &instruction, id in frame.func.values {
				moved |= check_uses(e, frame, ir.Value_ID(id), &instruction)
			}
		}
		used, cut := 0, false
		for &site in frame.sites {
			if !site.stack || site.pseudo != .None {
				continue
			}
			if used + site.size > STACK_BUDGET {
				site.stack, cut = false, true
				continue
			}
			used += site.size
		}
		if !cut {
			return
		}
	}
}

@(private = "file")
check_uses :: proc(
	e: ^Escape,
	frame: ^Frame,
	consumer: ir.Value_ID,
	instruction: ^ir.Instruction,
) -> bool {
	// What inlining and split took out of the blocks still names the cells it used.
	if frame.places[consumer].block == ir.NO_BLOCK {
		return false
	}
	ir.operands(&instruction.variant, &e.fields)
	moved := false
	for field in e.fields {
		if len(frame.points[field^]) == 0 || kept(e, frame, consumer, instruction, field) {
			continue
		}
		for site in frame.points[field^] {
			if frame.sites[site].stack {
				frame.sites[site].stack = false
				moved = true
			}
		}
	}
	return moved
}

// kept answers whether the operand in `field` stays in this frame where the instruction takes it.
@(private = "file")
kept :: proc(
	e: ^Escape,
	frame: ^Frame,
	consumer: ir.Value_ID,
	instruction: ^ir.Instruction,
	field: ^ir.Value_ID,
) -> bool {
	#partial switch &v in instruction.variant {
	case ir.Field_Load, ir.Field_Store, ir.Element_Load, ir.Element_Store:
		return true
	case ir.Length, ir.Set_Length, ir.Bounds_Check, ir.Layout_Test, ir.Null_Test, ir.Same_Cell:
		return true
	case ir.Compare, ir.Non_Null:
		return true
	case ir.Field_Store_Ref:
		return field == &v.cell || held_here(frame, v.cell, field^)
	case ir.Element_Store_Ref:
		return field == &v.array
	case ir.Reserve:
		// A buffer grown for a stack array would hang off a stack word, and the collector traces a
		// buffer only through its array.
		return false
	case ir.Call_Closure:
		if field == &v.callee {
			return true
		}
		callee, known := closure_function(frame.func^, v.callee)
		return known && !e.params[callee][argument_of(v.args, field)]
	case ir.Call:
		return !e.params[v.func][argument_of(v.args, field)]
	case ir.Make_Closure:
		// The closure cell holds its environment, as a Field_Store_Ref into it would.
		return !e.env[v.func] && held_here(frame, consumer, field^)
	}
	return false
}

// held_here wants the holder a stack cell of this frame, made in the loop of what it holds or a
// deeper one, so that it is made again, empty, before what it holds is.
@(private = "file")
held_here :: proc(frame: ^Frame, holder, value: ir.Value_ID) -> bool {
	holders := frame.points[holder]
	if len(holders) == 0 {
		return false
	}
	for h in holders {
		cell := frame.sites[h]
		if !cell.stack || cell.pseudo != .None {
			return false
		}
		inner := frame.loop[frame.places[cell.value].block]
		for s in frame.points[value] {
			outer := frame.loop[frame.places[frame.sites[s].value].block]
			if !nested(frame, inner, outer) {
				return false
			}
		}
	}
	return true
}

// nested takes NO_BLOCK for the function outside every loop.
@(private = "file")
nested :: proc(frame: ^Frame, inner, outer: ir.Block_ID) -> bool {
	if outer == ir.NO_BLOCK {
		return true
	}
	for header := inner; header != ir.NO_BLOCK; header = frame.outer[header] {
		if header == outer {
			return true
		}
	}
	return false
}

@(private = "file")
closure_function :: proc(func: ir.Func, closure: ir.Value_ID) -> (ir.Func_ID, bool) {
	#partial switch v in func.values[closure].variant {
	case ir.Make_Closure:
		return v.func, true
	case ir.Func_Ref:
		return v.func, true
	}
	return 0, false
}

@(private = "file")
argument_of :: proc(args: []ir.Value_ID, field: ^ir.Value_ID) -> int {
	for &arg, i in args {
		if &arg == field {
			return i
		}
	}
	unreachable()
}

// record_leaks answers whether a summary of the function learned that it lets something out.
@(private = "file")
record_leaks :: proc(e: ^Escape, id: ir.Func_ID) -> bool {
	learned := false
	for site in e.frames[id].sites {
		if site.stack {
			continue
		}
		switch site.pseudo {
		case .None:
		case .Env:
			learned ||= !e.env[id]
			e.env[id] = true
		case .Param:
			learned ||= !e.params[id][site.param]
			e.params[id][site.param] = true
		}
	}
	return learned
}

@(private = "file")
add_point :: proc(list: ^[dynamic]i32, site: i32) -> bool {
	for have in list {
		if have == site {
			return false
		}
	}
	if list.allocator.procedure == nil {
		list^ = make([dynamic]i32, context.temp_allocator)
	}
	append(list, site)
	return true
}

@(private = "file")
add_points :: proc(list: ^[dynamic]i32, sites: []i32) -> bool {
	grew := false
	for site in sites {
		grew |= add_point(list, site)
	}
	return grew
}
