package codegen_tests

import "core:fmt"
import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/ir"

/*
Instruction level tests, on IR built by hand. They emit at level none on purpose: the LLVM builder
folds an operation on two constants on the spot, and an optimizing pipeline would fold the rest, so
the operands are function parameters and no pipeline runs over them.
*/

// A module binding is a zeroed cell in the data segment, because abi.Tag.Undefined is zero: a
// tagged binding reads as undefined before its module init has run. A boolean is the one type that
// changes shape on the way in and out, i1 in a register and b64 in memory.
@(test)
a_module_binding_is_a_zeroed_global :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	number := ir.add_global(&p, "m1.n", ir.F64)
	flag := ir.add_global(&p, "m1.b", ir.BOOL)
	value := ir.add_global(&p, "m1.v", ir.TAGGED)

	id := ir.declare_func(&p, "m1.bindings", nil, ir.VOID, at(1))
	f := ir.begin_func(&p, id)
	loaded := ir.emit(&f, ir.BOOL, ir.Global_Load{global = flag}, at(2))
	ir.emit(&f, ir.VOID, ir.Global_Store{global = flag, value = loaded}, at(2))
	held := ir.emit(&f, ir.F64, ir.Global_Load{global = number}, at(2))
	ir.emit(&f, ir.VOID, ir.Global_Store{global = number, value = held}, at(2))
	tagged := ir.emit(&f, ir.TAGGED, ir.Global_Load{global = value}, at(2))
	ir.emit(&f, ir.VOID, ir.Global_Store{global = value, value = tagged}, at(2))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(3))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "globals")
	if text == "" {
		return
	}
	wants := []string {
		"@m1.n = internal global double 0.000000e+00",
		"@m1.b = internal global i64 0",
		"@m1.v = internal global %tsnc.tagged zeroinitializer",
		"trunc i64 ",
		"zext i1 ",
	}
	expect_text(t, text, wants)
}

// A fail site is a constant the runtime reads to say where the program stopped, and tsnc_fail never
// comes back.
@(test)
a_fail_site_carries_its_file_line_and_column :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	site := ir.fail_site(
		&p,
		abi.Fail_Site{file = "main.ts", line = 3, column = 5, error = .Non_Null_Assertion},
	)
	id := ir.declare_func(&p, "m1.fail", nil, ir.VOID, at(1))
	f := ir.begin_func(&p, id)
	ir.emit(&f, ir.VOID, ir.Fail{site = site}, at(2))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "fail")
	if text == "" {
		return
	}
	wants := []string {
		"private unnamed_addr constant [7 x i8] c\"main.ts\"",
		fmt.tprintf("i64 7, i32 3, i32 5, i32 %d", i32(abi.Runtime_Error.Non_Null_Assertion)),
		"call void @tsnc_fail(ptr",
		"unreachable",
	}
	expect_text(t, text, wants)
}

// The runtime takes a boolean as b64, so a call site widens its i1 and no export depends on how a C
// ABI passes a narrower one.
@(test)
a_runtime_call_widens_its_boolean :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	params := [?]ir.Type{ir.BOOL}
	id := ir.declare_func(&p, "m1.print", params[:], ir.VOID, at(1))
	f := ir.begin_func(&p, id)
	args := [?]ir.Value_ID{0}
	ir.emit(&f, ir.VOID, ir.Call_Runtime{export = .Console_Log, args = args[:]}, at(2))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(3))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "boolean")
	if text == "" {
		return
	}
	wants := []string{"zext i1 ", "call void @tsnc_console_log(i64 "}
	expect_text(t, text, wants)
}

// A Rest parameter takes its values from one array on the caller's stack, as long as the widest
// call of the function needs, and a call that passes none passes null.
@(test)
a_runtime_call_passes_its_rest_in_one_stack_array :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	params := [?]ir.Type{ir.TAGGED, ir.TAGGED}
	id := ir.declare_func(&p, "m1.print", params[:], ir.VOID, at(1))
	f := ir.begin_func(&p, id)
	to_stdout := ir.emit(&f, ir.BOOL, ir.Const_Bool{value = false}, at(2))
	three := [?]ir.Value_ID{to_stdout, 0, 1, 0}
	ir.emit(&f, ir.VOID, ir.Call_Runtime{export = .Console_Log, args = three[:]}, at(2))
	one := [?]ir.Value_ID{to_stdout, 1}
	ir.emit(&f, ir.VOID, ir.Call_Runtime{export = .Console_Log, args = one[:]}, at(3))
	none := [?]ir.Value_ID{to_stdout}
	ir.emit(&f, ir.VOID, ir.Call_Runtime{export = .Console_Log, args = none[:]}, at(4))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(5))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "rest")
	if text == "" {
		return
	}
	wants := []string {
		"alloca [3 x %tsnc.tagged]",
		"getelementptr inbounds %tsnc.tagged, ptr %4, i64 2",
		"store %tsnc.tagged %6, ptr %",
		"call void @tsnc_console_log(i64 0, ptr %4, i64 3)",
		"call void @tsnc_console_log(i64 0, ptr %4, i64 1)",
		"call void @tsnc_console_log(i64 0, ptr null, i64 0)",
	}
	expect_text(t, text, wants)
	testing.expectf(t, strings.count(text, "alloca") == 1, "one slot per function:\n%s", text)
}

// A tagged value crosses into the runtime as its two words, which every target passes alike.
@(test)
a_runtime_call_splits_a_tagged_value :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	params := [?]ir.Type{ir.TAGGED, ir.TAGGED}
	id := ir.declare_func(&p, "m1.same", params[:], ir.BOOL, at(1))
	f := ir.begin_func(&p, id)
	args := [?]ir.Value_ID{0, 1}
	equal := ir.emit(&f, ir.BOOL, ir.Call_Runtime{export = .Value_Equal, args = args[:]}, at(2))
	ir.emit(&f, ir.VOID, ir.Return{value = equal}, at(3))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "tagged-call")
	if text == "" {
		return
	}
	wants := []string {
		"declare i64 @tsnc_value_equal(i64, i64, i64, i64)",
		"extractvalue %tsnc.tagged %5, 0",
		"extractvalue %tsnc.tagged %5, 1",
		"extractvalue %tsnc.tagged %7, 0",
		"extractvalue %tsnc.tagged %7, 1",
		"call i64 @tsnc_value_equal(i64 ",
	}
	expect_text(t, text, wants)
}

// Every function but the entry point takes the closure convention of abi.Closure_Cell: the
// environment first, null in a direct call, a boolean as i64 both ways and a tagged value as its two
// words.
@(test)
a_function_takes_the_closure_convention :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	params := [?]ir.Type{ir.BOOL, ir.TAGGED, ir.F64}
	id := ir.declare_func(&p, "m1.pick", params[:], ir.BOOL, at(1))
	f := ir.begin_func(&p, id)
	args := [?]ir.Value_ID{0, 1, 2}
	picked := ir.emit(&f, ir.BOOL, ir.Call{func = id, env = ir.NO_VALUE, args = args[:]}, at(2))
	ir.emit(&f, ir.VOID, ir.Return{value = picked}, at(3))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "convention")
	if text == "" {
		return
	}
	wants := []string {
		"define void @tsnc_main()",
		"define internal i64 @m1.pick(ptr %env, i64 %0, i64 %1, i64 %2, double %3)",
		"trunc i64 %0 to i1",
		"insertvalue %tsnc.tagged undef, i64 %1, 0",
		"call i64 @m1.pick(ptr null, i64 ",
		"zext i1 ",
	}
	expect_text(t, text, wants)
}

@(test)
the_integer_types_map_to_llvm_integers :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)
	site := ir.fail_site(
		&p,
		abi.Fail_Site{file = "main.ts", line = 1, column = 1, error = .Index_Out_Of_Range},
	)
	numbers := ir.array_layout(&p, .Number)
	params := [?]ir.Type{ir.F64, ir.ref(numbers), ir.STR}
	id := ir.declare_func(&p, "m1.count", params[:], ir.F64, at(1))

	f := ir.begin_func(&p, id)
	number, array, text := ir.Value_ID(0), ir.Value_ID(1), ir.Value_ID(2)
	whole := ir.emit(&f, ir.I32, ir.Convert{value = number}, at(2))
	wide := ir.emit(&f, ir.I64, ir.Convert{value = number}, at(2))
	grown := ir.emit(&f, ir.I64, ir.Convert{value = whole}, at(2))
	seven := ir.emit(&f, ir.I32, ir.Const_Number{value = 7}, at(2))
	sum := ir.emit(&f, ir.I32, ir.Binary{op = .Add, left = whole, right = seven}, at(2))
	ir.emit(&f, ir.I32, ir.Binary{op = .Subtract, left = sum, right = whole}, at(2))
	product := ir.emit(&f, ir.I64, ir.Binary{op = .Multiply, left = wide, right = grown}, at(2))
	ir.emit(&f, ir.I32, ir.Binary{op = .Remainder, left = sum, right = seven}, at(2))
	ir.emit(&f, ir.F64, ir.Binary{op = .Remainder, left = number, right = number}, at(2))
	ir.emit(&f, ir.I64, ir.Unary{op = .Negate, operand = product}, at(2))
	ir.emit(&f, ir.BOOL, ir.Compare{op = .Less, left = whole, right = seven}, at(2))
	ir.emit(&f, ir.I32, ir.Binary{op = .Bit_And, left = whole, right = number}, at(2))
	unsigned := ir.Binary {
		op    = .Shift_Right_Unsigned,
		left  = product,
		right = seven,
	}
	ir.emit(&f, ir.I64, unsigned, at(2))
	ir.emit(&f, ir.I64, ir.Length{value = array}, at(2))
	check := ir.Bounds_Check {
		array        = array,
		index        = wide,
		not_integer  = site,
		out_of_range = site,
	}
	checked := ir.emit(&f, ir.I64, check, at(2))
	ir.emit(&f, ir.F64, ir.Element_Load{array = array, index = checked}, at(2))
	check.array, check.index = text, whole
	unit_index := ir.emit(&f, ir.I32, check, at(3))
	ir.emit(&f, ir.I32, ir.Unit_Load{text = text, index = unit_index}, at(3))
	back := ir.emit(&f, ir.F64, ir.Convert{value = product}, at(3))
	ir.emit(&f, ir.VOID, ir.Return{value = back}, at(3))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text_ll := llvm_text(t, &output, "integers")
	if text_ll == "" {
		return
	}
	wants := []string {
		"fptosi double %0 to i32",
		"fptosi double %0 to i64",
		"sext i32 ",
		"add nsw i32 ",
		"sub nsw i32 ",
		"mul nsw i64 ",
		"srem i32 ",
		"srem i64 ",
		"llvm.copysign.f64",
		"sub nsw i64 0, ",
		"icmp slt i32 ",
		"0x43E0000000000000",
		"llvm.fptosi.sat.i32.f64",
		"trunc i64 ",
		"lshr i32 ",
		"zext i32 ",
		"icmp ult i64 ",
		"zext i16 ",
		"sitofp i64 ",
	}
	expect_text(t, text_ll, wants)
}

// A push enters the runtime only for a full array, and Math.min picks with one comparison where its
// operands differ, so a loop of either stays inline on its common path.
@(test)
a_push_and_a_min_leave_the_runtime_to_the_rare_case :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	params := [?]ir.Type{ir.ref(ir.array_layout(&p, .Number)), ir.F64, ir.F64}
	id := ir.declare_func(&p, "m1.push_least", params[:], ir.VOID, at(1))
	f := ir.begin_func(&p, id)
	ir.emit(&f, ir.VOID, ir.Reserve{array = 0}, at(2))
	length := ir.emit(&f, ir.F64, ir.Length{value = 0}, at(2))
	least := ir.emit(&f, ir.F64, ir.Intrinsic{op = .Min, args = {length, 1}}, at(3))
	ir.emit(&f, ir.VOID, ir.Set_Length{array = 0, length = least}, at(3))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(4))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "push-min")
	if text == "" {
		return
	}
	wants := []string {
		"icmp eq i64",
		"call void @tsnc_array_reserve(ptr %0)",
		"fcmp one double",
		"fcmp olt double",
		"select i1",
		"call double @llvm.minimum.f64(",
		"fptosi double",
		"store i64",
	}
	expect_text(t, text, wants)
	testing.expectf(
		t,
		strings.count(text, "@tsnc_array_reserve(") == 2,
		"one declaration, one call:\n%s",
		text,
	)
}
