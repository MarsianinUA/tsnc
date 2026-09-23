package ir_tests

import "core:math"
import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/ir"
import "../../src/source"

// Everything lives in the temp allocator, which the test runner frees before each test, so a test
// frees nothing. The spans point at the start of a line of TEXT, so a position prints as `<line>:1`
// and the expected dump can be read without counting bytes.

@(private = "file")
TEXT :: "let total = 0\nfunction pick(a: number) {\n  return a\n}\npick(1)\nlog(total)\n"

@(test)
the_dump_shows_every_section_of_a_program :: proc(t: ^testing.T) {
	table := file_table()
	program := build_program(table)

	expect_dump(
		t,
		dump(table, program),
		{
			"; tsnc ir",
			"layout 1 object size 24",
			"  field 0 \"x\" number at 8",
			"  field 1 \"next\"? ref at 16",
			"layout 2 array number size 32",
			"global 0 total : f64",
			"string 0 \"hi\"",
			"fail 0 index_out_of_range at main.ts:3:10",
			"func 0 main_ts_init() -> void at main.ts:1:1",
			"  b0:",
			"    %0 = const 0 : f64 ; 1:1",
			"    global_store 0 = %0 ; 1:1",
			"    return ; 1:1",
			"func 1 pick(f64, f64) -> f64 at main.ts:2:1",
			"  b0:",
			"    %0 = param 0 : f64 ; 2:1",
			"    %1 = param 1 : f64 ; 2:1",
			"    %2 = lt %0, %1 : bool ; 3:1",
			"    branch %2 b1 b2 ; 3:1",
			"  b1:",
			"    %4 = const 1 : f64 ; 3:1",
			"    jump b3 ; 3:1",
			"  b2:",
			"    %6 = const 2 : f64 ; 3:1",
			"    jump b3 ; 3:1",
			"  b3:",
			"    %8 = phi [b1 %4], [b2 %6] : f64 ; 3:1",
			"    return %8 ; 3:1",
			"func 2 tsnc_main() -> void at main.ts:5:1",
			"  b0:",
			"    call 0() ; 5:1",
			"    %1 = const 1 : f64 ; 5:1",
			"    %2 = const 2 : f64 ; 5:1",
			"    %3 = call 1(%1, %2) : f64 ; 5:1",
			"    global_store 0 = %3 ; 5:1",
			"    %5 = alloc 1 : ref(1) ; 6:1",
			"    field_store %5 field 0 = %3 ; 6:1",
			"    field_store_ref %5 field 1 = %5 ; 6:1",
			"    %8 = string 0 : str ; 6:1",
			"    call_runtime tsnc_log_string(%8) ; 6:1",
			"    return ; 6:1",
			"init 0",
			"main 2",
			"unit 0 funcs 0 1 2",
		},
	)
}

@(test)
the_dump_spells_every_instruction :: proc(t: ^testing.T) {
	// The instructions the program above has no room for: the array accesses with their bounds
	// check, the tagged values, an intrinsic, a closure call, and the two terminators that are not
	// a jump, a branch or a return.
	table := file_table()
	program, sink := build_sink(table)

	expect_dump(
		t,
		func_dump(table, program, sink),
		{
			"func 0 sink(ref(1), tagged, closure, ref(2), ref(4)) -> void env 3 at main.ts:2:1",
			"  b0:",
			"    %0 = param 0 : ref(1) ; 2:1",
			"    %1 = param 1 : tagged ; 2:1",
			"    %2 = param 2 : closure ; 2:1",
			"    %3 = param 3 : ref(2) ; 2:1",
			"    %4 = param 4 : ref(4) ; 2:1",
			"    %5 = const 0.5 : f64 ; 3:1",
			"    %6 = bounds_check %0[%5] not_integer 0 out_of_range 1 : f64 ; 3:1",
			"    %7 = element_load %0[%6] : f64 ; 3:1",
			"    element_store %0[%6] = %7 ; 3:1",
			"    %9 = field_load %4 field 0 : f64 ; 3:1",
			"    %10 = add %7, %9 : f64 ; 3:1",
			"    %11 = neg %10 : f64 ; 3:1",
			"    %12 = intrinsic sqrt(%11) : f64 ; 3:1",
			"    %13 = box %12 : tagged ; 3:1",
			"    element_store_ref %3[%6] = %13 ; 3:1",
			"    %15 = tag_test %1 number : bool ; 3:1",
			"    branch %15 b1 b2 ; 3:1",
			"  b1:",
			"    %17 = unbox %1 : f64 ; 3:1",
			"    %18 = undefined : tagged ; 3:1",
			"    %19 = null : tagged ; 3:1",
			"    %20 = eq %17, %10 : bool ; 3:1",
			"    %21 = const true : bool ; 3:1",
			"    %22 = not %21 : bool ; 3:1",
			"    call_closure %2(%17) ; 3:1",
			"    unreachable ; 3:1",
			"  b2:",
			"    fail 1 ; 3:1",
		},
	)
}

@(test)
a_number_prints_as_the_shortest_form_that_reads_back :: proc(t: ^testing.T) {
	// The sign bit alone is negative zero: an Odin constant -0.0 folds to positive zero, and the
	// dump has to tell the two apart.
	negative_zero := transmute(f64)(u64(1) << 63)
	values := [?]f64 {
		0.1,
		negative_zero,
		math.nan_f64(),
		math.inf_f64(1),
		math.inf_f64(-1),
		1e21,
		9007199254740992, // 2 to the 53rd, the point above which the integers stop being exact
	}

	table := file_table()
	program, id := build_numbers(table, values[:])

	expect_dump(
		t,
		func_dump(table, program, id),
		{
			"func 0 numbers() -> void at main.ts:1:1",
			"  b0:",
			"    %0 = const 0.1 : f64 ; 1:1",
			"    %1 = const -0 : f64 ; 1:1",
			"    %2 = const NaN : f64 ; 1:1",
			"    %3 = const Inf : f64 ; 1:1",
			"    %4 = const -Inf : f64 ; 1:1",
			"    %5 = const 1000000000000000000000 : f64 ; 1:1",
			"    %6 = const 9007199254740992 : f64 ; 1:1",
			"    return ; 1:1",
		},
	)
}

@(test)
a_string_constant_keeps_every_unit :: proc(t: ^testing.T) {
	// A lone surrogate reaches the pool as the three WTF-8 bytes parse kept, and the dump has to
	// show the unit rather than the replacement character a rune decoder would make of it.
	p := ir.make_builder(context.temp_allocator)
	ir.intern_string(&p, "a\"b\\c\td")
	ir.intern_string(&p, "\u00e9\U0001F600")
	ir.intern_string(&p, "\xed\xa0\x80")
	id := ir.declare_func(&p, abi.MAIN_SYMBOL, nil, ir.VOID, {})
	f := ir.begin_func(&p, id)
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, {})
	ir.end_func(&f)
	program := ir.finish(&p, id, nil)

	output := dump(nil, program)
	lines := strings.split_lines(output, context.temp_allocator)
	testing.expect_value(t, lines[1], "string 0 \"a\\\"b\\\\c\\u0009d\"")
	testing.expect_value(t, lines[2], "string 1 \"\\u00e9\\ud83d\\ude00\"")
	testing.expect_value(t, lines[3], "string 2 \"\\ud800\"")
}

@(test)
the_same_program_dumps_to_the_same_bytes :: proc(t: ^testing.T) {
	// Determinism is what -emit-ir is held to: nothing printed comes out of a map, whose iteration
	// order changes between runs, so two builds of one program write the same text.
	table := file_table()
	first := dump(table, build_program(table))
	second := dump(table, build_program(table))

	testing.expect_value(t, first, second)
}

@(test)
a_position_counts_utf16_units_from_the_start_of_the_line :: proc(t: ^testing.T) {
	table := file_table()
	p := ir.make_builder(context.temp_allocator)
	id := ir.declare_func(&p, abi.MAIN_SYMBOL, nil, ir.VOID, at(table, 1))
	f := ir.begin_func(&p, id)
	// `return a` stands on line 3 after two spaces, so the return itself is at column 3.
	span := at(table, 3)
	span.start += 2
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, span)
	ir.end_func(&f)
	program := ir.finish(&p, id, nil)

	output := dump(table, program)
	lines := strings.split_lines(output, context.temp_allocator)
	testing.expect_value(t, lines[3], "    return ; 3:3")
}

@(test)
a_span_the_file_table_cannot_place_prints_as_question_marks :: proc(t: ^testing.T) {
	// A dump is read when a layer is broken, so a span pointing past the files it was built from
	// has to print as something rather than stop the dump or trip the assert inside source.
	table := file_table()
	lost := source.Span {
		file  = 9,
		start = 4,
		end   = 5,
	}
	p := ir.make_builder(context.temp_allocator)
	id := ir.declare_func(&p, abi.MAIN_SYMBOL, nil, ir.VOID, lost)
	f := ir.begin_func(&p, id)
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, {file = 1, start = 9999, end = 10000})
	ir.end_func(&f)

	lines := strings.split_lines(dump(table, ir.finish(&p, id, nil)), context.temp_allocator)

	testing.expect_value(t, lines[1], "func 0 tsnc_main() -> void at ?:?:?")
	testing.expect_value(t, lines[3], "    return ; ?:?")
}

@(test)
a_violation_names_the_place_it_was_found :: proc(t: ^testing.T) {
	table := file_table()
	program := build_program(table)
	violation := ir.Violation {
		kind  = .Use_Before_Definition,
		func  = 1,
		block = 2,
		value = 6,
	}

	b := strings.builder_make(context.temp_allocator)
	err := ir.write_violation(strings.to_writer(&b), table, program, violation)

	testing.expect_value(t, err, nil)
	testing.expect_value(
		t,
		strings.to_string(b),
		"pick:b2:%6: an operand whose definition does not reach every path to this use at main.ts:3:1\n",
	)
}

@(private = "file")
file_table :: proc() -> []source.File {
	table := make([]source.File, 2, context.temp_allocator)
	table[0] = source.make_file("lib.d.ts", "", context.temp_allocator)
	table[1] = source.make_file("main.ts", TEXT, context.temp_allocator)
	return table
}

// at is a span one byte wide at the start of a line of TEXT, so every position in a dump reads as
// `<line>:1` unless a test moves it.
@(private = "file")
at :: proc(table: []source.File, line: i32) -> source.Span {
	start := table[1].line_starts[line - 1]
	return {file = 1, start = start, end = start + 1}
}

@(private = "file")
dump :: proc(table: []source.File, program: ir.Program_IR) -> string {
	b := strings.builder_make(context.temp_allocator)
	err := ir.write_program(strings.to_writer(&b), table, program)
	assert(err == nil, "writing into a builder cannot fail")
	return strings.to_string(b)
}

@(private = "file")
func_dump :: proc(table: []source.File, program: ir.Program_IR, id: ir.Func_ID) -> string {
	b := strings.builder_make(context.temp_allocator)
	err := ir.write_func(strings.to_writer(&b), table, program, id)
	assert(err == nil, "writing into a builder cannot fail")
	return strings.to_string(b)
}

@(private = "file")
expect_dump :: proc(t: ^testing.T, output: string, lines: []string, loc := #caller_location) {
	body := strings.join(lines, "\n", context.temp_allocator)
	expected := strings.concatenate({body, "\n"}, context.temp_allocator)
	testing.expect_value(t, output, expected, loc = loc)
}

@(private = "file")
build_program :: proc(table: []source.File) -> ir.Program_IR {
	p := ir.make_builder(context.temp_allocator)

	fields := [?]ir.Slot {
		{name = "x", kind = .Number},
		{name = "next", kind = .Ref, optional = true},
	}
	cell := ir.object_layout(&p, fields[:])
	ir.array_layout(&p, .Number)
	total := ir.add_global(&p, "total", ir.F64)
	text := ir.intern_string(&p, "hi")
	ir.fail_site(
		&p,
		abi.Fail_Site{file = "main.ts", line = 3, column = 10, error = .Index_Out_Of_Range},
	)

	init := ir.declare_func(&p, "main_ts_init", nil, ir.VOID, at(table, 1))
	params := [?]ir.Type{ir.F64, ir.F64}
	pick := ir.declare_func(&p, "pick", params[:], ir.F64, at(table, 2))
	main := ir.declare_func(&p, abi.MAIN_SYMBOL, nil, ir.VOID, at(table, 5))

	f := ir.begin_func(&p, init)
	zero := ir.emit(&f, ir.F64, ir.Const_Number{value = 0}, at(table, 1))
	ir.emit(&f, ir.VOID, ir.Global_Store{global = total, value = zero}, at(table, 1))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(table, 1))
	ir.end_func(&f)

	g := ir.begin_func(&p, pick)
	then_block := ir.add_block(&g)
	else_block := ir.add_block(&g)
	join := ir.add_block(&g)
	less := ir.emit(&g, ir.BOOL, ir.Compare{op = .Less, left = 0, right = 1}, at(table, 3))
	branch := ir.Branch {
		condition  = less,
		then_block = then_block,
		else_block = else_block,
	}
	ir.emit(&g, ir.VOID, branch, at(table, 3))
	ir.use_block(&g, then_block)
	one := ir.emit(&g, ir.F64, ir.Const_Number{value = 1}, at(table, 3))
	ir.emit(&g, ir.VOID, ir.Jump{target = join}, at(table, 3))
	ir.use_block(&g, else_block)
	two := ir.emit(&g, ir.F64, ir.Const_Number{value = 2}, at(table, 3))
	ir.emit(&g, ir.VOID, ir.Jump{target = join}, at(table, 3))
	ir.use_block(&g, join)
	result := ir.phi(&g, ir.F64, at(table, 3))
	ir.phi_incoming(&g, result, then_block, one)
	ir.phi_incoming(&g, result, else_block, two)
	ir.emit(&g, ir.VOID, ir.Return{value = result}, at(table, 3))
	ir.end_func(&g)

	m := ir.begin_func(&p, main)
	ir.emit(&m, ir.VOID, ir.Call{func = init}, at(table, 5))
	first := ir.emit(&m, ir.F64, ir.Const_Number{value = 1}, at(table, 5))
	second := ir.emit(&m, ir.F64, ir.Const_Number{value = 2}, at(table, 5))
	args := [?]ir.Value_ID{first, second}
	chosen := ir.emit(&m, ir.F64, ir.Call{func = pick, args = args[:]}, at(table, 5))
	ir.emit(&m, ir.VOID, ir.Global_Store{global = total, value = chosen}, at(table, 5))
	point := ir.emit(&m, ir.ref(cell), ir.Alloc{layout = cell}, at(table, 6))
	ir.emit(&m, ir.VOID, ir.Field_Store{cell = point, field = 0, value = chosen}, at(table, 6))
	ir.emit(&m, ir.VOID, ir.Field_Store_Ref{cell = point, field = 1, value = point}, at(table, 6))
	greeting := ir.emit(&m, ir.STR, ir.Const_String{text = text}, at(table, 6))
	logged := [?]ir.Value_ID{greeting}
	ir.emit(&m, ir.VOID, ir.Call_Runtime{export = .Log_String, args = logged[:]}, at(table, 6))
	ir.emit(&m, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(table, 6))
	ir.end_func(&m)

	order := [?]ir.Func_ID{init}
	return ir.finish(&p, main, order[:])
}

@(private = "file")
build_sink :: proc(table: []source.File) -> (ir.Program_IR, ir.Func_ID) {
	p := ir.make_builder(context.temp_allocator)

	numbers := ir.array_layout(&p, .Number)
	tagged := ir.array_layout(&p, .Tagged)
	captured := [?]abi.Slot_Kind{.Tagged}
	env := ir.environment_layout(&p, captured[:])
	fields := [?]ir.Slot{{name = "x", kind = .Number}}
	cell := ir.object_layout(&p, fields[:])
	not_integer := ir.fail_site(
		&p,
		abi.Fail_Site{file = "main.ts", line = 3, column = 3, error = .Index_Not_Integer},
	)
	out_of_range := ir.fail_site(
		&p,
		abi.Fail_Site{file = "main.ts", line = 3, column = 5, error = .Index_Out_Of_Range},
	)

	params := [?]ir.Type{ir.ref(numbers), ir.TAGGED, ir.CLOSURE, ir.ref(tagged), ir.ref(cell)}
	sink := ir.declare_func(&p, "sink", params[:], ir.VOID, at(table, 2), env)

	f := ir.begin_func(&p, sink)
	done := ir.add_block(&f)
	broken := ir.add_block(&f)
	line := at(table, 3)
	index := ir.emit(&f, ir.F64, ir.Const_Number{value = 0.5}, line)
	check := ir.Bounds_Check {
		array        = 0,
		index        = index,
		not_integer  = not_integer,
		out_of_range = out_of_range,
	}
	checked := ir.emit(&f, ir.F64, check, line)
	element := ir.emit(&f, ir.F64, ir.Element_Load{array = 0, index = checked}, line)
	ir.emit(&f, ir.VOID, ir.Element_Store{array = 0, index = checked, value = element}, line)
	field := ir.emit(&f, ir.F64, ir.Field_Load{cell = 4, field = 0}, line)
	sum := ir.emit(&f, ir.F64, ir.Binary{op = .Add, left = element, right = field}, line)
	negated := ir.emit(&f, ir.F64, ir.Unary{op = .Negate, operand = sum}, line)
	root_args := [?]ir.Value_ID{negated}
	root := ir.emit(&f, ir.F64, ir.Intrinsic{op = .Sqrt, args = root_args[:]}, line)
	boxed := ir.emit(&f, ir.TAGGED, ir.Box{value = root}, line)
	ir.emit(&f, ir.VOID, ir.Element_Store_Ref{array = 3, index = checked, value = boxed}, line)
	is_number := ir.emit(&f, ir.BOOL, ir.Tag_Test{value = 1, tag = .Number}, line)
	branch := ir.Branch {
		condition  = is_number,
		then_block = done,
		else_block = broken,
	}
	ir.emit(&f, ir.VOID, branch, line)

	ir.use_block(&f, done)
	unboxed := ir.emit(&f, ir.F64, ir.Unbox{value = 1}, line)
	ir.emit(&f, ir.TAGGED, ir.Const_Undefined{}, line)
	ir.emit(&f, ir.TAGGED, ir.Const_Null{}, line)
	ir.emit(&f, ir.BOOL, ir.Compare{op = .Equal, left = unboxed, right = sum}, line)
	flag := ir.emit(&f, ir.BOOL, ir.Const_Bool{value = true}, line)
	ir.emit(&f, ir.BOOL, ir.Unary{op = .Not, operand = flag}, line)
	closure_args := [?]ir.Value_ID{unboxed}
	ir.emit(&f, ir.VOID, ir.Call_Closure{callee = 2, args = closure_args[:]}, line)
	ir.emit(&f, ir.VOID, ir.Unreachable{}, line)

	ir.use_block(&f, broken)
	ir.emit(&f, ir.VOID, ir.Fail{site = out_of_range}, line)
	ir.end_func(&f)

	return ir.finish(&p, sink, nil), sink
}

@(private = "file")
build_numbers :: proc(table: []source.File, values: []f64) -> (ir.Program_IR, ir.Func_ID) {
	p := ir.make_builder(context.temp_allocator)
	id := ir.declare_func(&p, "numbers", nil, ir.VOID, at(table, 1))

	f := ir.begin_func(&p, id)
	for value in values {
		ir.emit(&f, ir.F64, ir.Const_Number{value = value}, at(table, 1))
	}
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(table, 1))
	ir.end_func(&f)

	return ir.finish(&p, id, nil), id
}
