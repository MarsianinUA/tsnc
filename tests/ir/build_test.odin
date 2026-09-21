package ir_tests

import "core:mem/virtual"
import "core:testing"

import "../../src/abi"
import "../../src/ir"
import "../../src/source"

@(test)
a_function_of_two_parameters_returns_their_sum :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	params := [?]ir.Type{ir.F64, ir.F64}
	add := ir.declare_func(&p, "add", params[:], ir.F64, at(1))

	f := ir.begin_func(&p, add)
	sum := ir.emit(&f, ir.F64, ir.Binary{op = .Add, left = 0, right = 1}, at(2))
	ir.emit(&f, ir.VOID, ir.Return{value = sum}, at(3))
	ir.end_func(&f)

	func := p.funcs[add]
	testing.expect_value(t, len(func.blocks), 1)
	testing.expect_value(t, len(func.values), 4)
	// begin_func emits the parameters, so parameter i is value i.
	testing.expect_value(t, func.values[0].variant.(ir.Param).index, i32(0))
	testing.expect_value(t, func.values[1].variant.(ir.Param).index, i32(1))
	testing.expect_value(t, func.values[0].type, ir.F64)
	testing.expect_value(t, sum, ir.Value_ID(2))
	testing.expect_value(t, func.values[sum].type, ir.F64)

	entry := func.blocks[ir.ENTRY]
	testing.expect_value(t, len(entry.instructions), 4)
	last := entry.instructions[len(entry.instructions) - 1]
	testing.expect(t, ir.terminates(func.values[last].variant), "a block ends in a terminator")
}

@(test)
an_instruction_keeps_the_span_it_was_emitted_with :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	id := ir.declare_func(&p, "f", nil, ir.VOID, at(1))

	f := ir.begin_func(&p, id)
	value := ir.emit(&f, ir.F64, ir.Const_Number{value = 2}, at(7))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(9))
	ir.end_func(&f)

	testing.expect_value(t, p.funcs[id].values[value].span, at(7))
}

@(test)
a_branch_joins_through_a_phi :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	params := [?]ir.Type{ir.BOOL}
	pick := ir.declare_func(&p, "pick", params[:], ir.F64, at(1))

	f := ir.begin_func(&p, pick)
	then_block := ir.add_block(&f)
	else_block := ir.add_block(&f)
	join := ir.add_block(&f)
	branch := ir.Branch {
		condition  = 0,
		then_block = then_block,
		else_block = else_block,
	}
	ir.emit(&f, ir.VOID, branch, at(2))

	ir.use_block(&f, then_block)
	one := ir.emit(&f, ir.F64, ir.Const_Number{value = 1}, at(3))
	ir.emit(&f, ir.VOID, ir.Jump{target = join}, at(4))

	ir.use_block(&f, else_block)
	two := ir.emit(&f, ir.F64, ir.Const_Number{value = 2}, at(5))
	ir.emit(&f, ir.VOID, ir.Jump{target = join}, at(6))

	ir.use_block(&f, join)
	result := ir.phi(&f, ir.F64, at(7))
	ir.phi_incoming(&f, result, then_block, one)
	ir.phi_incoming(&f, result, else_block, two)
	ir.emit(&f, ir.VOID, ir.Return{value = result}, at(8))
	ir.end_func(&f)

	func := p.funcs[pick]
	edges := func.values[result].variant.(ir.Phi).incoming
	testing.expect_value(t, len(func.blocks), 4)
	testing.expect_value(t, func.values[result].type, ir.F64)
	testing.expect_value(t, len(edges), 2)
	testing.expect_value(t, edges[0], ir.Incoming{block = then_block, value = one})
	testing.expect_value(t, edges[1], ir.Incoming{block = else_block, value = two})
}

@(test)
a_loop_header_phi_learns_its_back_edge_after_the_body :: proc(t: ^testing.T) {
	// `let i = 0; while (i < n) { i = i + 1 }`. This is the shape that decides how a phi is built:
	// the header needs the value the body produces, and the body is built after the header.
	p := ir.make_builder(context.temp_allocator)
	params := [?]ir.Type{ir.F64}
	count := ir.declare_func(&p, "count", params[:], ir.F64, at(1))

	f := ir.begin_func(&p, count)
	header := ir.add_block(&f)
	body := ir.add_block(&f)
	exit := ir.add_block(&f)
	zero := ir.emit(&f, ir.F64, ir.Const_Number{value = 0}, at(2))
	ir.emit(&f, ir.VOID, ir.Jump{target = header}, at(3))

	ir.use_block(&f, header)
	i := ir.phi(&f, ir.F64, at(4))
	ir.phi_incoming(&f, i, ir.ENTRY, zero)
	more := ir.emit(&f, ir.BOOL, ir.Compare{op = .Less, left = i, right = 0}, at(5))
	loop := ir.Branch {
		condition  = more,
		then_block = body,
		else_block = exit,
	}
	ir.emit(&f, ir.VOID, loop, at(6))

	ir.use_block(&f, body)
	one := ir.emit(&f, ir.F64, ir.Const_Number{value = 1}, at(7))
	next := ir.emit(&f, ir.F64, ir.Binary{op = .Add, left = i, right = one}, at(8))
	ir.emit(&f, ir.VOID, ir.Jump{target = header}, at(9))
	ir.phi_incoming(&f, i, body, next)

	ir.use_block(&f, exit)
	ir.emit(&f, ir.VOID, ir.Return{value = i}, at(10))
	ir.end_func(&f)

	edges := p.funcs[count].values[i].variant.(ir.Phi).incoming
	testing.expect_value(t, len(edges), 2)
	testing.expect_value(t, edges[0], ir.Incoming{block = ir.ENTRY, value = zero})
	testing.expect_value(t, edges[1], ir.Incoming{block = body, value = next})
}

@(test)
a_terminator_closes_its_block :: proc(t: ^testing.T) {
	// `if (c) { return 1 } return 2`: after the return, lower opens a block of its own for what
	// follows instead of emitting into a block that control has already left.
	p := ir.make_builder(context.temp_allocator)
	id := ir.declare_func(&p, "answer", nil, ir.F64, at(1))

	f := ir.begin_func(&p, id)
	one := ir.emit(&f, ir.F64, ir.Const_Number{value = 1}, at(2))
	ir.emit(&f, ir.VOID, ir.Return{value = one}, at(3))
	rest := ir.add_block(&f)
	ir.use_block(&f, rest)
	two := ir.emit(&f, ir.F64, ir.Const_Number{value = 2}, at(4))
	ir.emit(&f, ir.VOID, ir.Return{value = two}, at(5))
	ir.end_func(&f)

	func := p.funcs[id]
	testing.expect_value(t, len(func.blocks[ir.ENTRY].instructions), 2)
	testing.expect_value(t, len(func.blocks[rest].instructions), 2)
}

@(test)
a_call_names_a_function_that_is_not_built_yet :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	total := ir.add_global(&p, "total", ir.F64)
	helper := ir.declare_func(&p, "helper", nil, ir.F64, at(1))
	caller := ir.declare_func(&p, "caller", nil, ir.VOID, at(2))

	f := ir.begin_func(&p, caller)
	answer := ir.emit(&f, ir.F64, ir.Call{func = helper}, at(3))
	ir.emit(&f, ir.VOID, ir.Global_Store{global = total, value = answer}, at(4))
	read := ir.emit(&f, ir.F64, ir.Global_Load{global = total}, at(5))
	args := [?]ir.Value_ID{read}
	logged := ir.emit(&f, ir.VOID, ir.Call_Runtime{export = .Log_String, args = args[:]}, at(6))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(7))
	ir.end_func(&f)

	g := ir.begin_func(&p, helper)
	one := ir.emit(&g, ir.F64, ir.Const_Number{value = 1}, at(8))
	ir.emit(&g, ir.VOID, ir.Return{value = one}, at(9))
	ir.end_func(&g)

	func := p.funcs[caller]
	testing.expect_value(t, func.values[answer].variant.(ir.Call).func, helper)
	testing.expect_value(t, p.globals[total].name, "total")
	testing.expect_value(t, p.funcs[helper].values[one].type, ir.F64)

	// The arguments were built in the caller's own storage, so emit kept a copy of its own.
	kept := func.values[logged].variant.(ir.Call_Runtime).args
	testing.expect_value(t, len(kept), 1)
	testing.expect_value(t, kept[0], read)
	testing.expect(t, raw_data(kept) != raw_data(args[:]), "emit copies the list it keeps")
}

@(test)
finish_freezes_the_program :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	init := ir.declare_func(&p, "main_ts_init", nil, ir.VOID, at(1))
	main := ir.declare_func(&p, abi.MAIN_SYMBOL, nil, ir.VOID, at(2))
	build_return(&p, init)
	build_return(&p, main)
	order := [?]ir.Func_ID{init}

	program := ir.finish(&p, main, order[:])

	testing.expect_value(t, len(program.funcs), 2)
	testing.expect_value(t, program.funcs[program.main].name, abi.MAIN_SYMBOL)
	testing.expect_value(t, len(program.init_order), 1)
	testing.expect_value(t, program.init_order[0], init)
	// v1 compiles the whole program as one unit.
	testing.expect_value(t, len(program.units), 1)
	testing.expect_value(t, len(program.units[0].funcs), 2)
	testing.expect_value(t, program.units[0].funcs[1], main)
	// Layout row 0 is reserved for NO_LAYOUT and no program names it.
	testing.expect_value(t, len(program.layouts), 1)
}

@(test)
the_program_outlives_the_scratch_it_was_built_from :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	program: ir.Program_IR
	{
		p := ir.make_builder(allocator)
		fields := make([]ir.Slot, 1, context.temp_allocator)
		fields[0] = {
			name = "x",
			kind = .Number,
		}
		layout := ir.object_layout(&p, fields[:])
		id := ir.declare_func(&p, "make_point", nil, ir.ref(layout), at(1))

		f := ir.begin_func(&p, id)
		cell := ir.emit(&f, ir.ref(layout), ir.Alloc{layout = layout}, at(2))
		ir.emit(&f, ir.VOID, ir.Return{value = cell}, at(3))
		ir.end_func(&f)
		program = ir.finish(&p, id, nil)
	}
	free_all(context.temp_allocator) // the scratch the layout was described in is gone

	func := program.funcs[0]
	testing.expect_value(t, func.name, "make_point")
	testing.expect_value(t, len(func.values), 2)
	layout := program.layouts[func.result.layout]
	testing.expect_value(t, len(layout.fields), 1)
	testing.expect_value(t, layout.fields[0].offset, size_of(abi.Cell_Header))
}

// at stands in for the place in the source an instruction came from. The tests compare spans, so
// only the shape matters.
@(private = "file")
at :: proc(offset: i32) -> source.Span {
	return {file = 1, start = offset, end = offset + 1}
}

@(private = "file")
build_return :: proc(p: ^ir.Program_Builder, id: ir.Func_ID) {
	f := ir.begin_func(p, id)
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(0))
	ir.end_func(&f)
}
