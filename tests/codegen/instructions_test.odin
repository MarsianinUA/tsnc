package codegen_tests

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/codegen"
import "../../src/ir"
import "../../src/target"

/*
Instruction level tests, on IR built by hand. They emit at level none on purpose: the LLVM builder
folds an operation on two constants on the spot, and an optimizing pipeline would fold the rest, so
the operands are function parameters and no pipeline runs over them.
*/

@(test)
a_loop_header_phi_takes_its_back_edge :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	params := [?]ir.Type{ir.F64}
	id := ir.declare_func(&p, "m1.count", params[:], ir.F64, at(1))
	f := ir.begin_func(&p, id)
	header := ir.add_block(&f)
	body := ir.add_block(&f)
	exit := ir.add_block(&f)

	zero := ir.emit(&f, ir.F64, ir.Const_Number{value = 0}, at(2))
	ir.emit(&f, ir.VOID, ir.Jump{target = header}, at(2))

	ir.use_block(&f, header)
	counter := ir.phi(&f, ir.F64, at(3))
	less := ir.emit(&f, ir.BOOL, ir.Compare{op = .Less, left = counter, right = 0}, at(3))
	ir.emit(&f, ir.VOID, ir.Branch{condition = less, then_block = body, else_block = exit}, at(3))

	ir.use_block(&f, body)
	one := ir.emit(&f, ir.F64, ir.Const_Number{value = 1}, at(4))
	next := ir.emit(&f, ir.F64, ir.Binary{op = .Add, left = counter, right = one}, at(4))
	ir.emit(&f, ir.VOID, ir.Jump{target = header}, at(4))

	ir.phi_incoming(&f, counter, ir.ENTRY, zero)
	ir.phi_incoming(&f, counter, body, next)

	ir.use_block(&f, exit)
	ir.emit(&f, ir.VOID, ir.Return{value = counter}, at(5))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "phi")
	if text == "" {
		return
	}
	wants := []string{"phi double [", "fcmp olt double", "br i1 ", "fadd double"}
	expect_text(t, text, wants)
}

// IEEE everywhere, which is what === asks of numbers. Not_Equal is the unordered predicate, so NaN
// differs from everything, itself included.
@(test)
number_comparisons_use_ieee_predicates :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	params := [?]ir.Type{ir.F64, ir.F64}
	id := ir.declare_func(&p, "m1.compare", params[:], ir.F64, at(1))
	f := ir.begin_func(&p, id)
	for op in ir.Compare_Op {
		ir.emit(&f, ir.BOOL, ir.Compare{op = op, left = 0, right = 1}, at(2))
	}
	ir.emit(&f, ir.VOID, ir.Return{value = 0}, at(3))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "compare")
	if text == "" {
		return
	}
	wants := []string {
		"fcmp olt double",
		"fcmp ole double",
		"fcmp ogt double",
		"fcmp oge double",
		"fcmp oeq double",
		"fcmp une double",
	}
	expect_text(t, text, wants)
}

// The bitwise operators are the ones ECMAScript defines: both operands go through ToInt32, the
// shift count is taken modulo 32, and the 32 bit answer comes back as a double - unsigned for >>>.
@(test)
bitwise_operators_go_through_to_int32 :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	params := [?]ir.Type{ir.F64, ir.F64}
	id := ir.declare_func(&p, "m1.bits", params[:], ir.F64, at(1))
	f := ir.begin_func(&p, id)
	for op in ir.Binary_Op {
		ir.emit(&f, ir.F64, ir.Binary{op = op, left = 0, right = 1}, at(2))
	}
	ir.emit(&f, ir.F64, ir.Unary{op = .Bit_Not, operand = 0}, at(2))
	ir.emit(&f, ir.VOID, ir.Return{value = 0}, at(3))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "bits")
	if text == "" {
		return
	}
	wants := []string {
		// ToInt32: truncate, wrap modulo 2^32, fold into the signed range, convert with saturation
		// so that NaN and the infinities answer 0.
		"@llvm.trunc.f64(",
		"frem double",
		"@llvm.fptosi.sat.i32.f64(",
		"and i32 ", // the shift count modulo 32
		"shl i32 ",
		"ashr i32 ",
		"lshr i32 ",
		"or i32 ",
		"xor i32 ",
		"sitofp i32 ",
		"uitofp i32 ", // only >>> answers an unsigned value
		// The plain arithmetic beside it.
		"fadd double",
		"fsub double",
		"fmul double",
		"fdiv double",
		"frem double",
	}
	expect_text(t, text, wants)
}

// ** is ECMAScript exponentiation: with a base of 1 or -1 and an exponent that is NaN or an
// infinity it answers NaN, where the pow of C99 answers 1.
@(test)
exponentiation_answers_nan_for_a_unit_base :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	params := [?]ir.Type{ir.F64, ir.F64}
	id := ir.declare_func(&p, "m1.power", params[:], ir.F64, at(1))
	f := ir.begin_func(&p, id)
	power := ir.emit(&f, ir.F64, ir.Binary{op = .Power, left = 0, right = 1}, at(2))
	ir.emit(&f, ir.VOID, ir.Return{value = power}, at(3))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "power")
	if text == "" {
		return
	}
	wants := []string {
		"@llvm.pow.f64(",
		"@llvm.fabs.f64(",
		"fcmp uno double", // an exponent that is NaN
		"0x7FF0000000000000", // an exponent that is an infinity
		"select i1 ",
	}
	expect_text(t, text, wants)
}

// A tagged value is the two words of abi.Tagged: the tag, and a payload that holds a double, a
// widened boolean or an address.
@(test)
a_tagged_value_is_two_words :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	params := [?]ir.Type{ir.F64}
	id := ir.declare_func(&p, "m1.tag", params[:], ir.F64, at(1))
	f := ir.begin_func(&p, id)
	boxed := ir.emit(&f, ir.TAGGED, ir.Box{value = 0}, at(2))
	ir.emit(&f, ir.BOOL, ir.Tag_Test{value = boxed, tag = .Number}, at(2))
	number := ir.emit(&f, ir.F64, ir.Unbox{value = boxed}, at(2))
	ir.emit(&f, ir.TAGGED, ir.Const_Undefined{}, at(2))
	ir.emit(&f, ir.TAGGED, ir.Const_Null{}, at(2))
	ir.emit(&f, ir.VOID, ir.Return{value = number}, at(3))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "tagged")
	if text == "" {
		return
	}
	wants := []string {
		"%tsnc.tagged = type { i64, i64 }",
		"insertvalue %tsnc.tagged",
		"extractvalue %tsnc.tagged",
		fmt.tprintf("i64 %d", u64(abi.Tag.Number)),
		"icmp eq i64",
	}
	expect_text(t, text, wants)
}

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

// A block no call can reach stays out of the module: nothing promises that its operands dominate
// their uses, and lower leaves such blocks behind after a return or a diverging call.
@(test)
a_block_that_cannot_be_reached_is_left_out :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	id := ir.declare_func(&p, "m1.dead", nil, ir.VOID, at(1))
	f := ir.begin_func(&p, id)
	dead := ir.add_block(&f)
	exit := ir.add_block(&f)
	ir.emit(&f, ir.VOID, ir.Jump{target = exit}, at(2))

	ir.use_block(&f, dead)
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(3))

	ir.use_block(&f, exit)
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(4))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "dead")
	if text == "" {
		return
	}
	expect_text(t, text, []string{"b2:"})
	testing.expectf(t, !strings.contains(text, "b1:"), "the dead block was emitted:\n%s", text)
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
	to_stdout := ir.emit(&f, ir.BOOL, ir.Const_Bool{value = false}, at(2))
	args := [?]ir.Value_ID{to_stdout, 0}
	ir.emit(&f, ir.VOID, ir.Call_Runtime{export = .Console_Boolean, args = args[:]}, at(2))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(3))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "boolean")
	if text == "" {
		return
	}
	wants := []string{"zext i1 ", "call void @tsnc_console_boolean(i64 0, i64 "}
	expect_text(t, text, wants)
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
		"extractvalue %tsnc.tagged %0, 0",
		"extractvalue %tsnc.tagged %0, 1",
		"extractvalue %tsnc.tagged %1, 0",
		"extractvalue %tsnc.tagged %1, 1",
		"call i64 @tsnc_value_equal(i64 ",
	}
	expect_text(t, text, wants)
}

// The table is the other half of the one in codegen: an llvm intrinsic where LLVM 20 has one, a
// libm call otherwise.
@(test)
every_number_function_reaches_llvm :: proc(t: ^testing.T) {
	calls := [ir.Intrinsic_Op]string {
		.Abs   = "@llvm.fabs.f64(",
		.Sqrt  = "@llvm.sqrt.f64(",
		.Floor = "@llvm.floor.f64(",
		.Ceil  = "@llvm.ceil.f64(",
		.Trunc = "@llvm.trunc.f64(",
		.Sin   = "@llvm.sin.f64(",
		.Cos   = "@llvm.cos.f64(",
		.Tan   = "@llvm.tan.f64(",
		.Asin  = "@llvm.asin.f64(",
		.Acos  = "@llvm.acos.f64(",
		.Atan  = "@llvm.atan.f64(",
		.Atan2 = "@llvm.atan2.f64(",
		.Sinh  = "@llvm.sinh.f64(",
		.Cosh  = "@llvm.cosh.f64(",
		.Tanh  = "@llvm.tanh.f64(",
		.Asinh = "@asinh(",
		.Acosh = "@acosh(",
		.Atanh = "@atanh(",
		.Exp   = "@llvm.exp.f64(",
		.Expm1 = "@expm1(",
		.Log   = "@llvm.log.f64(",
		.Log1p = "@log1p(",
		.Log2  = "@llvm.log2.f64(",
		.Log10 = "@llvm.log10.f64(",
		.Cbrt  = "@cbrt(",
	}

	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)
	params := [?]ir.Type{ir.F64, ir.F64}
	for op in ir.Intrinsic_Op {
		arity := 2 if op == .Atan2 else 1
		name := fmt.tprintf("m1.%v", op)
		id := ir.declare_func(&p, name, params[:arity], ir.F64, at(1))
		f := ir.begin_func(&p, id)
		args := [?]ir.Value_ID{0, 1}
		result := ir.emit(&f, ir.F64, ir.Intrinsic{op = op, args = args[:arity]}, at(2))
		ir.emit(&f, ir.VOID, ir.Return{value = result}, at(3))
		ir.end_func(&f)
	}

	output := finish_program(t, &p, main)
	text := llvm_text(t, &output, "numbers")
	if text == "" {
		return
	}
	for op in ir.Intrinsic_Op {
		testing.expectf(
			t,
			strings.contains(text, calls[op]),
			"%v is not called as %q",
			op,
			calls[op],
		)
	}
}

// An instruction whose runtime arrives with milestone 5 is an error, not a crash. lower refuses
// every construct that would build one, so no program reaches this.
@(test)
an_instruction_without_a_runtime_is_an_error :: proc(t: ^testing.T) {
	p := ir.make_builder(context.temp_allocator)
	main := declare_main(&p)

	fields := [?]ir.Slot{{name = "x", kind = .Number}}
	layout := ir.object_layout(&p, fields[:])
	id := ir.declare_func(&p, "m1.make", nil, ir.VOID, at(1))
	f := ir.begin_func(&p, id)
	ir.emit(&f, ir.ref(layout), ir.Alloc{layout = layout}, at(2))
	ir.emit(&f, ir.VOID, ir.Return{value = ir.NO_VALUE}, at(3))
	ir.end_func(&f)

	output := finish_program(t, &p, main)
	err: codegen.Error
	{
		// emit names the instruction at error level, and the test runner fails a test on any error
		// log.
		context.logger = log.nil_logger()
		err = codegen.emit(
			&output,
			output.units[0],
			target.HOST,
			.none,
			.LLVM_IR,
			"dist/codegen-alloc.ll",
		)
	}
	testing.expect_value(t, err, codegen.Error.Unsupported_Instruction)
}
