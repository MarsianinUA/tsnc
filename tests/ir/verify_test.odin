package ir_tests

import "core:testing"

import "../../src/abi"
import "../../src/ir"
import "../../src/source"

// Everything lives in the temp allocator, which the test runner frees before each test, so a test
// frees nothing.
//
// The builder refuses to make most of the programs below: it asserts on a phi out of place and on
// an instruction after a terminator, which is the point of having it. So a malformed program is
// built well and then broken, and each test says in one line what it broke.

@(test)
a_program_the_builder_made_has_no_violations :: proc(t: ^testing.T) {
	// Every shape milestone 4 lowers: a branch joined by a phi, a loop header with a back edge,
	// the heap and tagged instructions, and the two terminators that are not a return.
	program := build_clean()

	found := ir.verify(program, context.temp_allocator)

	expect_none(t, found)
}

@(test)
a_block_nothing_reaches_is_not_a_violation :: proc(t: ^testing.T) {
	// lower opens a block for the statements after a return, and nothing ever jumps to it.
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	f := ir.begin_func(&p, main)
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(1))
	rest := ir.add_block(&f)
	ir.use_block(&f, rest)
	dead := ir.emit(&f, ir.F64, ir.Const_Number{value = 1}, at(2))
	ir.emit(
		&f,
		ir.VOID,
		ir.Global_Store{global = ir.add_global(&p, "x", ir.F64), value = dead},
		at(2),
	)
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(2))
	ir.end_func(&f)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	expect_none(t, found)
}

@(test)
a_block_without_a_terminator_is_a_violation :: proc(t: ^testing.T) {
	program, main := build_return()
	block := &program.funcs[main].blocks[ir.ENTRY]
	block.instructions = block.instructions[:len(block.instructions) - 1]

	found := ir.verify(program, context.temp_allocator)

	expect_one(t, found, .Missing_Terminator)
	testing.expect_value(t, found[0].block, ir.ENTRY)
	testing.expect_value(t, found[0].value, ir.NO_VALUE)
}

@(test)
a_terminator_before_the_end_of_its_block_is_a_violation :: proc(t: ^testing.T) {
	// The same return listed twice: the first one ends the block early, the second one ends it.
	program, main := build_return()
	block := &program.funcs[main].blocks[ir.ENTRY]
	twice := make([]ir.Value_ID, 2, context.temp_allocator)
	twice[0] = block.instructions[0]
	twice[1] = block.instructions[0]
	block.instructions = twice

	found := ir.verify(program, context.temp_allocator)

	expect_one(t, found, .Misplaced_Terminator)
}

@(test)
a_value_of_one_branch_does_not_reach_the_block_after_the_join :: proc(t: ^testing.T) {
	// The case only dominance catches. The value is defined in a block the walk reaches before the
	// block that uses it, so an order-only check takes it; but control can reach the join through
	// the other branch, where the value was never computed. lower has to put a phi here.
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)
	params := [?]ir.Type{ir.BOOL}
	leak := ir.declare_func(&p, "leak", params[:], ir.VOID, at(1))
	build_return_body(&p, main)

	f := ir.begin_func(&p, leak)
	then_block := ir.add_block(&f)
	else_block := ir.add_block(&f)
	join := ir.add_block(&f)
	branch := ir.Branch {
		condition  = 0,
		then_block = then_block,
		else_block = else_block,
	}
	ir.emit(&f, ir.VOID, branch, at(1))
	ir.use_block(&f, then_block)
	only_here := ir.emit(&f, ir.F64, ir.Const_Number{value = 1}, at(2))
	ir.emit(&f, ir.VOID, ir.Jump{target = join}, at(2))
	ir.use_block(&f, else_block)
	ir.emit(&f, ir.VOID, ir.Jump{target = join}, at(3))
	ir.use_block(&f, join)
	ir.emit(&f, ir.F64, ir.Unary{op = .Negate, operand = only_here}, at(4))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(4))
	ir.end_func(&f)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	expect_one(t, found, .Use_Before_Definition)
	testing.expect_value(t, found[0].func, leak)
	testing.expect_value(t, found[0].block, join)
}

@(test)
a_function_that_was_never_built_is_a_violation :: proc(t: ^testing.T) {
	// declare_func reserves a row so that a call can name a function built later; a row nothing
	// ever fills is a function lower forgot.
	p := ir.make_builder(context.temp_allocator)
	ir.declare_func(&p, "forgotten", nil, ir.VOID, at(1))
	main := declare_main(&p)
	build_return_body(&p, main)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	expect_one(t, found, .Missing_Body)
	testing.expect_value(t, found[0].block, ir.NO_BLOCK)
}

@(test)
a_phi_after_another_instruction_is_a_violation :: proc(t: ^testing.T) {
	// A phi stands for what a block received on the way in, so it comes before the work of the
	// block. The builder asserts on this; opt rewrites instructions without the builder.
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)
	late := ir.declare_func(&p, "late", nil, ir.F64, at(1))
	build_return_body(&p, main)

	f := ir.begin_func(&p, late)
	body := ir.add_block(&f)
	zero := ir.emit(&f, ir.F64, ir.Const_Number{value = 0}, at(1))
	ir.emit(&f, ir.VOID, ir.Jump{target = body}, at(1))
	ir.use_block(&f, body)
	value := ir.phi(&f, ir.F64, at(2))
	ir.phi_incoming(&f, value, ir.ENTRY, zero)
	ir.emit(&f, ir.F64, ir.Const_Number{value = 1}, at(2))
	ir.emit(&f, ir.VOID, ir.Return{value = value}, at(2))
	ir.end_func(&f)
	program := ir.finish(&p, main, nil)

	block := &program.funcs[late].blocks[body]
	block.instructions[0], block.instructions[1] = block.instructions[1], block.instructions[0]
	found := ir.verify(program, context.temp_allocator)

	expect_one(t, found, .Misplaced_Phi)
}

@(test)
an_instruction_that_names_what_is_not_there_is_a_violation :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)
	lost := ir.declare_func(&p, "lost", nil, ir.VOID, at(1))
	build_return_body(&p, main)

	f := ir.begin_func(&p, lost)
	one := ir.emit(&f, ir.F64, ir.Const_Number{value = 1}, at(1))
	ir.emit(&f, ir.F64, ir.Binary{op = .Add, left = one, right = 99}, at(2))
	ir.emit(&f, ir.VOID, ir.Jump{target = 7}, at(3))
	ir.end_func(&f)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	expect_kinds(t, found, {.Unknown_Value, .Unknown_Block})
}

@(test)
a_result_type_that_does_not_suit_the_instruction_is_a_violation :: proc(t: ^testing.T) {
	// The caller states the type of what it emits, so the verifier is what holds it to the variant.
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	f := ir.begin_func(&p, main)
	ir.emit(&f, ir.BOOL, ir.Const_Number{value = 1}, at(1))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(2))
	ir.end_func(&f)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	expect_one(t, found, .Result_Type)
}

@(test)
a_rest_parameter_of_the_runtime_takes_any_number_of_tagged_values :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	params := [?]ir.Type{ir.TAGGED, ir.F64}
	log := ir.declare_func(&p, "log", params[:], ir.VOID, at(1))
	main := declare_main(&p)
	build_return_body(&p, main)

	f := ir.begin_func(&p, log)
	err := ir.emit(&f, ir.BOOL, ir.Const_Bool{value = false}, at(2))
	none := [?]ir.Value_ID{err}
	ir.emit(&f, ir.VOID, ir.Call_Runtime{export = .Console_Log, args = none[:]}, at(2))
	three := [?]ir.Value_ID{err, 0, 0, 0}
	ir.emit(&f, ir.VOID, ir.Call_Runtime{export = .Console_Log, args = three[:]}, at(3))
	number := [?]ir.Value_ID{err, 0, 1}
	ir.emit(&f, ir.VOID, ir.Call_Runtime{export = .Console_Log, args = number[:]}, at(4))
	ir.emit(&f, ir.VOID, ir.Call_Runtime{export = .Console_Log}, at(5))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(6))
	ir.end_func(&f)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	// No values and three are both fine; a number in the rest is not, and neither is a call that
	// leaves out the fixed parameter before it.
	expect_kinds(t, found, {.Operand_Type, .Argument_Count})
}

@(test)
a_phi_needs_one_edge_per_predecessor :: proc(t: ^testing.T) {
	program, _ := build_branch(.Missing_Edge)

	found := ir.verify(program, context.temp_allocator)

	expect_one(t, found, .Phi_Edges)
}

@(test)
a_phi_edge_comes_from_a_predecessor :: proc(t: ^testing.T) {
	program, _ := build_branch(.Foreign_Edge)

	found := ir.verify(program, context.temp_allocator)

	expect_one(t, found, .Phi_Edges)
}

@(test)
a_store_matches_the_slot_it_writes :: proc(t: ^testing.T) {
	// The rule the collector rests on: a reference enters a heap cell only through a store whose
	// name ends in _Ref, and nothing else goes through one.
	p := ir.make_builder(context.temp_allocator)
	fields := [?]ir.Slot{{name = "x", kind = .Number}, {name = "next", kind = .Ref}}
	cell := ir.object_layout(&p, fields[:])
	main := declare_main(&p)

	f := ir.begin_func(&p, main)
	point := ir.emit(&f, ir.ref(cell), ir.Alloc{layout = cell}, at(1))
	number := ir.emit(&f, ir.F64, ir.Const_Number{value = 1}, at(1))
	ir.emit(&f, ir.VOID, ir.Field_Store{cell = point, field = 1, value = point}, at(2))
	ir.emit(&f, ir.VOID, ir.Field_Store_Ref{cell = point, field = 0, value = number}, at(3))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(4))
	ir.end_func(&f)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	expect_kinds(t, found, {.Store_Kind, .Store_Kind})
}

@(test)
an_element_access_takes_the_answer_of_its_bounds_check :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	numbers := ir.array_layout(&p, .Number)
	params := [?]ir.Type{ir.ref(numbers)}
	read := ir.declare_func(&p, "read", params[:], ir.F64, at(1))
	main := declare_main(&p)
	build_return_body(&p, main)

	f := ir.begin_func(&p, read)
	index := ir.emit(&f, ir.F64, ir.Const_Number{value = 0}, at(1))
	element := ir.emit(&f, ir.F64, ir.Element_Load{array = 0, index = index}, at(2))
	ir.emit(&f, ir.VOID, ir.Return{value = element}, at(2))
	ir.end_func(&f)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	expect_one(t, found, .Unchecked_Index)
}

@(test)
an_operand_of_the_wrong_type_is_a_violation :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	params := [?]ir.Type{ir.BOOL}
	add := ir.declare_func(&p, "add", params[:], ir.F64, at(1))
	main := declare_main(&p)
	build_return_body(&p, main)

	f := ir.begin_func(&p, add)
	one := ir.emit(&f, ir.F64, ir.Const_Number{value = 1}, at(1))
	sum := ir.emit(&f, ir.F64, ir.Binary{op = .Add, left = 0, right = one}, at(2))
	ir.emit(&f, ir.VOID, ir.Return{value = sum}, at(2))
	ir.end_func(&f)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	expect_one(t, found, .Operand_Type)
}

@(test)
a_tagged_parameter_of_the_runtime_takes_only_a_tagged_value :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	params := [?]ir.Type{ir.TAGGED, ir.F64}
	same := ir.declare_func(&p, "same", params[:], ir.BOOL, at(1))
	main := declare_main(&p)
	build_return_body(&p, main)

	f := ir.begin_func(&p, same)
	tagged := [?]ir.Value_ID{0, 0}
	equal := ir.emit(&f, ir.BOOL, ir.Call_Runtime{export = .Value_Equal, args = tagged[:]}, at(2))
	number := [?]ir.Value_ID{0, 1}
	ir.emit(&f, ir.BOOL, ir.Call_Runtime{export = .Value_Equal, args = number[:]}, at(3))
	ir.emit(&f, ir.VOID, ir.Return{value = equal}, at(4))
	ir.end_func(&f)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	// The first call passes two tagged values, the second a number where a tagged value goes.
	expect_one(t, found, .Operand_Type)
}

@(test)
a_tagged_result_of_the_runtime_is_a_tagged_value :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	params := [?]ir.Type{ir.ref(ir.array_layout(&p, .Number))}
	last := ir.declare_func(&p, "last", params[:], ir.TAGGED, at(1))
	main := declare_main(&p)
	build_return_body(&p, main)

	f := ir.begin_func(&p, last)
	array := [?]ir.Value_ID{0}
	popped := ir.emit(&f, ir.TAGGED, ir.Call_Runtime{export = .Array_Pop, args = array[:]}, at(2))
	ir.emit(&f, ir.F64, ir.Call_Runtime{export = .Array_Pop, args = array[:]}, at(3))
	ir.emit(&f, ir.VOID, ir.Return{value = popped}, at(4))
	ir.end_func(&f)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	// pop answers `number | undefined`, never a bare number, even from a number array.
	expect_one(t, found, .Result_Type)
}

@(test)
a_return_carries_the_result_of_its_function :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	empty := ir.declare_func(&p, "empty", nil, ir.F64, at(1))
	main := declare_main(&p)
	build_return_body(&p, main)

	f := ir.begin_func(&p, empty)
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(1))
	ir.end_func(&f)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	expect_one(t, found, .Operand_Type)
}

@(test)
a_call_takes_one_argument_per_parameter :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	params := [?]ir.Type{ir.F64, ir.F64}
	add := ir.declare_func(&p, "add", params[:], ir.F64, at(1))
	main := declare_main(&p)

	a := ir.begin_func(&p, add)
	sum := ir.emit(&a, ir.F64, ir.Binary{op = .Add, left = 0, right = 1}, at(1))
	ir.emit(&a, ir.VOID, ir.Return{value = sum}, at(1))
	ir.end_func(&a)

	f := ir.begin_func(&p, main)
	one := ir.emit(&f, ir.F64, ir.Const_Number{value = 1}, at(1))
	args := [?]ir.Value_ID{one}
	ir.emit(&f, ir.F64, ir.Call{func = add, args = args[:]}, at(1))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(1))
	ir.end_func(&f)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	expect_one(t, found, .Argument_Count)
}

@(test)
an_id_outside_the_program_is_a_violation :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	f := ir.begin_func(&p, main)
	one := ir.emit(&f, ir.F64, ir.Const_Number{value = 1}, at(1))
	ir.emit(&f, ir.VOID, ir.Global_Store{global = 7, value = one}, at(1))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(1))
	ir.end_func(&f)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	expect_one(t, found, .Unknown_Id)
}

@(test)
an_entry_point_takes_nothing_and_returns_void :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	params := [?]ir.Type{ir.F64}
	main := ir.declare_func(&p, abi.MAIN_SYMBOL, params[:], ir.VOID, at(1))
	build_return_body(&p, main)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	expect_one(t, found, .Entry_Signature)
	testing.expect_value(t, found[0].func, main)
	testing.expect_value(t, found[0].block, ir.NO_BLOCK)
}

@(test)
every_fault_of_a_program_is_reported :: proc(t: ^testing.T) {
	// One pass shows everything wrong with a layer, the way one pass shows every diagnostic.
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	f := ir.begin_func(&p, main)
	flag := ir.emit(&f, ir.BOOL, ir.Const_Bool{value = true}, at(1))
	ir.emit(&f, ir.F64, ir.Binary{op = .Add, left = flag, right = flag}, at(2))
	ir.emit(&f, ir.VOID, ir.Global_Store{global = 3, value = flag}, at(3))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(4))
	ir.end_func(&f)

	found := ir.verify(ir.finish(&p, main, nil), context.temp_allocator)

	expect_kinds(t, found, {.Operand_Type, .Operand_Type, .Unknown_Id})
}

@(private = "file")
Edge_Fault :: enum {
	None,
	Missing_Edge, // one edge for two predecessors
	Foreign_Edge, // an edge from a block that does not branch here
}

@(private = "file")
build_branch :: proc(fault: Edge_Fault) -> (ir.Program_IR, ir.Func_ID) {
	p := ir.make_builder(context.temp_allocator)
	params := [?]ir.Type{ir.BOOL, ir.F64}
	pick := ir.declare_func(&p, "pick", params[:], ir.F64, at(1))
	main := declare_main(&p)
	build_return_body(&p, main)

	f := ir.begin_func(&p, pick)
	then_block := ir.add_block(&f)
	else_block := ir.add_block(&f)
	join := ir.add_block(&f)
	branch := ir.Branch {
		condition  = 0,
		then_block = then_block,
		else_block = else_block,
	}
	ir.emit(&f, ir.VOID, branch, at(1))
	ir.use_block(&f, then_block)
	one := ir.emit(&f, ir.F64, ir.Const_Number{value = 1}, at(2))
	ir.emit(&f, ir.VOID, ir.Jump{target = join}, at(2))
	ir.use_block(&f, else_block)
	two := ir.emit(&f, ir.F64, ir.Const_Number{value = 2}, at(3))
	ir.emit(&f, ir.VOID, ir.Jump{target = join}, at(3))

	ir.use_block(&f, join)
	result := ir.phi(&f, ir.F64, at(4))
	ir.phi_incoming(&f, result, then_block, one)
	switch fault {
	case .None:
		ir.phi_incoming(&f, result, else_block, two)
	case .Missing_Edge:
	case .Foreign_Edge:
		// The entry branches to the two blocks above, never to the join, and parameter 1 is there
		// on that edge, so only the edge itself is wrong.
		ir.phi_incoming(&f, result, ir.ENTRY, 1)
	}
	ir.emit(&f, ir.VOID, ir.Return{value = result}, at(4))
	ir.end_func(&f)

	return ir.finish(&p, main, nil), pick
}

@(test)
the_cells_generated_code_fills_itself_pass :: proc(t: ^testing.T) {
	// A string goes into a Ref slot and comes back out as a Str, a Str takes a bounds check, and
	// a cell names a table row that lists its own layout's fields in another order.
	expect_none(t, ir.verify(build_heap(.None), context.temp_allocator))
}

@(test)
a_heap_instruction_of_the_wrong_kind_is_a_violation :: proc(t: ^testing.T) {
	cases := [?]struct {
		fault: Heap_Fault,
		kind:  ir.Violation_Kind,
	} {
		{.Foreign_Table, .Operand_Type},
		{.Length_Of_Object, .Operand_Type},
		{.Element_Of_Str, .Operand_Type},
		{.Null_Str, .Result_Type},
		{.Array_Of_Object, .Operand_Type},
		// lower gives two objects one layout wherever check lets them meet, so a comparison of two
		// layouts is a join that went missing.
		{.Refs_Of_Two_Layouts, .Operand_Type},
	}
	for c in cases {
		found := ir.verify(build_heap(c.fault), context.temp_allocator)
		testing.expectf(t, len(found) == 1 && found[0].kind == c.kind, "%v: %v", c.fault, found)
	}
}

@(test)
closures_with_the_environment_of_their_function_pass :: proc(t: ^testing.T) {
	expect_none(t, ir.verify(build_closures(.None), context.temp_allocator))
}

@(test)
an_environment_that_does_not_match_its_function_is_a_violation :: proc(t: ^testing.T) {
	for fault in Closure_Fault {
		if fault == .None {
			continue
		}
		found := ir.verify(build_closures(fault), context.temp_allocator)
		testing.expectf(
			t,
			len(found) == 1 && found[0].kind == .Environment,
			"%v: %v",
			fault,
			found,
		)
	}
}

@(private = "file")
Closure_Fault :: enum {
	None,
	Env_Without_Environment, // an Env in a function that takes none
	Environment_Not_An_Environment, // a Func.env that names an object layout
	Direct_Call_With_Environment,
	Func_Ref_With_Environment,
	Env_Operand_Missing, // Make_Closure of a function with an environment, given none
	Env_Operand_Given, // Make_Closure of a function without one, given one
	Env_Operand_Of_Other_Layout,
	Closure_Of_Main,
	Closure_Of_Undescribed,
	Entry_With_Environment,
}

// build_closures makes `inner`, which takes an environment, and `plain`, which does not, and
// closures of both in `outer`; the fault breaks one of them.
@(private = "file")
build_closures :: proc(fault: Closure_Fault) -> ir.Program_IR {
	p := ir.make_builder(context.temp_allocator)
	slots := [?]abi.Slot_Kind{.Number}
	env := ir.environment_layout(&p, slots[:])
	if fault == .Environment_Not_An_Environment {
		fields := [?]ir.Slot{{name = "x", kind = .Number}}
		env = ir.object_layout(&p, fields[:])
	}
	other_slots := [?]abi.Slot_Kind{.Tagged}
	other := ir.environment_layout(&p, other_slots[:])

	params := [?]ir.Type{ir.F64}
	inner := ir.declare_func(&p, "inner", params[:], ir.F64, at(1), env)
	ir.describe_func(&p, inner, "inner", 1, true)
	plain := ir.declare_func(&p, "plain", nil, ir.VOID, at(2))
	ir.describe_func(&p, plain, "", 0, false)
	undescribed := ir.declare_func(&p, "undescribed", nil, ir.VOID, at(3))
	outer := ir.declare_func(&p, "outer", params[:], ir.VOID, at(4))
	main_env := env if fault == .Entry_With_Environment else ir.NO_LAYOUT
	main := ir.declare_func(&p, abi.MAIN_SYMBOL, nil, ir.VOID, at(5), main_env)
	build_return_body(&p, undescribed)
	build_return_body(&p, main)

	f := ir.begin_func(&p, inner)
	cell := ir.emit(&f, ir.ref(env), ir.Env{}, at(1))
	held := ir.emit(&f, ir.F64, ir.Field_Load{cell = cell, field = 0}, at(1))
	ir.emit(&f, ir.VOID, ir.Return{value = held}, at(1))
	ir.end_func(&f)

	g := ir.begin_func(&p, plain)
	if fault == .Env_Without_Environment {
		ir.emit(&g, ir.ref(env), ir.Env{}, at(2))
	}
	ir.emit(&g, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(2))
	ir.end_func(&g)

	h := ir.begin_func(&p, outer)
	made := ir.emit(&h, ir.ref(env), ir.Alloc{layout = env}, at(4))
	ir.emit(&h, ir.VOID, ir.Field_Store{cell = made, field = 0, value = 0}, at(4))
	stranger := ir.emit(&h, ir.ref(other), ir.Alloc{layout = other}, at(4))
	given := made
	#partial switch fault {
	case .Env_Operand_Missing:
		given = ir.NO_VALUE
	case .Env_Operand_Of_Other_Layout:
		given = stranger
	}
	ir.emit(&h, ir.CLOSURE, ir.Make_Closure{func = inner, env = given}, at(4))
	bare := made if fault == .Env_Operand_Given else ir.NO_VALUE
	ir.emit(&h, ir.CLOSURE, ir.Make_Closure{func = plain, env = bare}, at(4))
	referred := plain
	#partial switch fault {
	case .Func_Ref_With_Environment:
		referred = inner
	case .Closure_Of_Main:
		referred = main
	case .Closure_Of_Undescribed:
		referred = undescribed
	}
	ir.emit(&h, ir.CLOSURE, ir.Func_Ref{func = referred}, at(4))
	if fault == .Direct_Call_With_Environment {
		args := [?]ir.Value_ID{0}
		ir.emit(&h, ir.F64, ir.Call{func = inner, args = args[:]}, at(4))
	}
	ir.emit(&h, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(4))
	ir.end_func(&h)

	return ir.finish(&p, main, nil)
}

@(private = "file")
Heap_Fault :: enum {
	None,
	Foreign_Table, // an Alloc whose header names a row of another layout
	Length_Of_Object,
	Element_Of_Str,
	Null_Str,
	Array_Of_Object,
	Refs_Of_Two_Layouts,
}

@(private = "file")
build_heap :: proc(fault: Heap_Fault) -> ir.Program_IR {
	p := ir.make_builder(context.temp_allocator)
	fields := [?]ir.Slot{{name = "a", kind = .Number}, {name = "b", kind = .Ref}}
	cell := ir.object_layout(&p, fields[:])
	swapped := ir.object_table(&p, cell, {"b", "a"})
	other_fields := [?]ir.Slot{{name = "c", kind = .Number}, {name = "d", kind = .Number}}
	other := ir.object_layout(&p, other_fields[:])
	other_swapped := ir.object_table(&p, other, {"d", "c"})
	numbers := ir.array_layout(&p, .Number)
	not_integer := ir.fail_site(
		&p,
		abi.Fail_Site{file = "main.ts", line = 1, column = 1, error = .Index_Not_Integer},
	)
	out_of_range := ir.fail_site(
		&p,
		abi.Fail_Site{file = "main.ts", line = 1, column = 1, error = .Index_Out_Of_Range},
	)
	params := [?]ir.Type{ir.STR, ir.ref(numbers)}
	sink := ir.declare_func(&p, "sink", params[:], ir.VOID, at(1))
	main := declare_main(&p)
	build_return_body(&p, main)

	f := ir.begin_func(&p, sink)
	text, array := ir.Value_ID(0), ir.Value_ID(1)
	table := other_swapped if fault == .Foreign_Table else swapped
	object := ir.emit(&f, ir.ref(cell), ir.Alloc{layout = cell, table = table}, at(1))
	ir.emit(&f, ir.VOID, ir.Field_Store_Ref{cell = object, field = 1, value = text}, at(1))
	read := ir.emit(&f, ir.STR, ir.Field_Load{cell = object, field = 1}, at(1))
	measured := object if fault == .Length_Of_Object else read
	ir.emit(&f, ir.F64, ir.Length{value = measured}, at(1))
	ir.emit(&f, ir.F64, ir.Length{value = array}, at(1))
	zero := ir.emit(&f, ir.F64, ir.Const_Number{value = 0}, at(1))
	check := ir.Bounds_Check {
		array        = text,
		index        = zero,
		not_integer  = not_integer,
		out_of_range = out_of_range,
	}
	checked := ir.emit(&f, ir.F64, check, at(1))
	if fault == .Element_Of_Str {
		ir.emit(&f, ir.F64, ir.Element_Load{array = text, index = checked}, at(1))
	}
	ir.emit(&f, ir.STR if fault == .Null_Str else ir.ref(cell), ir.Const_Null{}, at(1))
	count := ir.emit(&f, ir.F64, ir.Const_Number{value = 2}, at(1))
	made := cell if fault == .Array_Of_Object else numbers
	ir.emit(&f, ir.ref(made), ir.New_Array{layout = made, length = count}, at(1))
	ir.emit(&f, ir.BOOL, ir.Layout_Test{cell = object, layout = cell}, at(1))
	if fault == .Refs_Of_Two_Layouts {
		stranger := ir.emit(&f, ir.ref(other), ir.Alloc{layout = other}, at(1))
		same := ir.Compare {
			op    = .Equal,
			left  = object,
			right = stranger,
		}
		ir.emit(&f, ir.BOOL, same, at(1))
	}
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(1))
	ir.end_func(&f)

	return ir.finish(&p, main, nil)
}

@(private = "file")
build_clean :: proc() -> ir.Program_IR {
	p := ir.make_builder(context.temp_allocator)

	numbers := ir.array_layout(&p, .Number)
	tagged := ir.array_layout(&p, .Tagged)
	captured := [?]abi.Slot_Kind{.Tagged}
	env := ir.environment_layout(&p, captured[:])
	fields := [?]ir.Slot{{name = "x", kind = .Number}}
	cell := ir.object_layout(&p, fields[:])
	total := ir.add_global(&p, "total", ir.F64)
	text := ir.intern_string(&p, "hi")
	not_integer := ir.fail_site(
		&p,
		abi.Fail_Site{file = "main.ts", line = 1, column = 1, error = .Index_Not_Integer},
	)
	out_of_range := ir.fail_site(
		&p,
		abi.Fail_Site{file = "main.ts", line = 1, column = 3, error = .Index_Out_Of_Range},
	)

	init := ir.declare_func(&p, "main_ts_init", nil, ir.VOID, at(1))
	counting := [?]ir.Type{ir.F64}
	count := ir.declare_func(&p, "count", counting[:], ir.F64, at(2))
	sinking := [?]ir.Type{ir.ref(numbers), ir.TAGGED, ir.CLOSURE, ir.ref(tagged), ir.ref(cell)}
	sink := ir.declare_func(&p, "sink", sinking[:], ir.VOID, at(3), env)
	main := declare_main(&p)

	f := ir.begin_func(&p, init)
	zero := ir.emit(&f, ir.F64, ir.Const_Number{value = 0}, at(1))
	ir.emit(&f, ir.VOID, ir.Global_Store{global = total, value = zero}, at(1))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(1))
	ir.end_func(&f)

	// `let i = 0; while (i < n) { i = i + 1 } return i`: the header phi learns its back edge only
	// once the body is built, so this is the shape dominance has to accept.
	g := ir.begin_func(&p, count)
	header := ir.add_block(&g)
	body := ir.add_block(&g)
	exit := ir.add_block(&g)
	start := ir.emit(&g, ir.F64, ir.Const_Number{value = 0}, at(2))
	ir.emit(&g, ir.VOID, ir.Jump{target = header}, at(2))
	ir.use_block(&g, header)
	i := ir.phi(&g, ir.F64, at(2))
	ir.phi_incoming(&g, i, ir.ENTRY, start)
	more := ir.emit(&g, ir.BOOL, ir.Compare{op = .Less, left = i, right = 0}, at(2))
	loop := ir.Branch {
		condition  = more,
		then_block = body,
		else_block = exit,
	}
	ir.emit(&g, ir.VOID, loop, at(2))
	ir.use_block(&g, body)
	one := ir.emit(&g, ir.F64, ir.Const_Number{value = 1}, at(2))
	next := ir.emit(&g, ir.F64, ir.Binary{op = .Add, left = i, right = one}, at(2))
	ir.emit(&g, ir.VOID, ir.Jump{target = header}, at(2))
	ir.phi_incoming(&g, i, body, next)
	ir.use_block(&g, exit)
	ir.emit(&g, ir.VOID, ir.Return{value = i}, at(2))
	ir.end_func(&g)

	s := ir.begin_func(&p, sink)
	done := ir.add_block(&s)
	broken := ir.add_block(&s)
	index := ir.emit(&s, ir.F64, ir.Const_Number{value = 0}, at(3))
	check := ir.Bounds_Check {
		array        = 0,
		index        = index,
		not_integer  = not_integer,
		out_of_range = out_of_range,
	}
	checked := ir.emit(&s, ir.F64, check, at(3))
	element := ir.emit(&s, ir.F64, ir.Element_Load{array = 0, index = checked}, at(3))
	ir.emit(&s, ir.VOID, ir.Element_Store{array = 0, index = checked, value = element}, at(3))
	field := ir.emit(&s, ir.F64, ir.Field_Load{cell = 4, field = 0}, at(3))
	sum := ir.emit(&s, ir.F64, ir.Binary{op = .Add, left = element, right = field}, at(3))
	root_args := [?]ir.Value_ID{sum}
	root := ir.emit(&s, ir.F64, ir.Intrinsic{op = .Sqrt, args = root_args[:]}, at(3))
	boxed := ir.emit(&s, ir.TAGGED, ir.Box{value = root}, at(3))
	ir.emit(&s, ir.VOID, ir.Element_Store_Ref{array = 3, index = checked, value = boxed}, at(3))
	ir.emit(&s, ir.VOID, ir.Field_Store{cell = 4, field = 0, value = sum}, at(3))
	is_number := ir.emit(&s, ir.BOOL, ir.Tag_Test{value = 1, tags = {.Number}}, at(3))
	branch := ir.Branch {
		condition  = is_number,
		then_block = done,
		else_block = broken,
	}
	ir.emit(&s, ir.VOID, branch, at(3))
	ir.use_block(&s, done)
	unboxed := ir.emit(&s, ir.F64, ir.Unbox{value = 1}, at(3))
	closure_args := [?]ir.Value_ID{unboxed}
	ir.emit(&s, ir.VOID, ir.Call_Closure{callee = 2, args = closure_args[:]}, at(3))
	ir.emit(&s, ir.VOID, ir.Unreachable{}, at(3))
	ir.use_block(&s, broken)
	ir.emit(&s, ir.VOID, ir.Fail{site = out_of_range}, at(3))
	ir.end_func(&s)

	m := ir.begin_func(&p, main)
	ir.emit(&m, ir.VOID, ir.Call{func = init}, at(4))
	argument := ir.emit(&m, ir.F64, ir.Const_Number{value = 3}, at(4))
	args := [?]ir.Value_ID{argument}
	counted := ir.emit(&m, ir.F64, ir.Call{func = count, args = args[:]}, at(4))
	ir.emit(&m, ir.VOID, ir.Global_Store{global = total, value = counted}, at(4))
	greeting := ir.emit(&m, ir.STR, ir.Const_String{text = text}, at(4))
	logged := [?]ir.Value_ID{greeting}
	ir.emit(&m, ir.VOID, ir.Call_Runtime{export = .Log_String, args = logged[:]}, at(4))
	ir.emit(&m, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(4))
	ir.end_func(&m)

	order := [?]ir.Func_ID{init}
	return ir.finish(&p, main, order[:])
}

@(private = "file")
build_return :: proc() -> (ir.Program_IR, ir.Func_ID) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)
	build_return_body(&p, main)
	return ir.finish(&p, main, nil), main
}

@(private = "file")
declare_main :: proc(p: ^ir.Program_Builder) -> ir.Func_ID {
	return ir.declare_func(p, abi.MAIN_SYMBOL, nil, ir.VOID, at(1))
}

// build_return_body fills a function whose result is void with the one instruction it needs.
@(private = "file")
build_return_body :: proc(p: ^ir.Program_Builder, id: ir.Func_ID) {
	f := ir.begin_func(p, id)
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(1))
	ir.end_func(&f)
}

// at stands in for the place in the source an instruction came from. The verifier never reads the
// text, so only the shape matters.
@(private = "file")
at :: proc(offset: i32) -> source.Span {
	return {file = 1, start = offset, end = offset + 1}
}

@(private = "file")
expect_none :: proc(t: ^testing.T, found: []ir.Violation, loc := #caller_location) {
	testing.expectf(t, len(found) == 0, "expected no violation, got %v", found, loc = loc)
}

@(private = "file")
expect_one :: proc(
	t: ^testing.T,
	found: []ir.Violation,
	kind: ir.Violation_Kind,
	loc := #caller_location,
) {
	expect_kinds(t, found, {kind}, loc)
}

@(private = "file")
expect_kinds :: proc(
	t: ^testing.T,
	found: []ir.Violation,
	kinds: []ir.Violation_Kind,
	loc := #caller_location,
) {
	if !testing.expectf(
		t,
		len(found) == len(kinds),
		"expected %v, got %v",
		kinds,
		found,
		loc = loc,
	) {
		return
	}
	for kind, i in kinds {
		testing.expect_value(t, found[i].kind, kind, loc = loc)
	}
}
