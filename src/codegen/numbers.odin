package codegen

import "core:math"
import "core:strings"

import "../ir"
import "../llvm"

/*
Numbers follow ECMAScript, not the machine, and two places say so.

The bitwise and shift operators work on 32 bit integers that ToInt32 takes from a double: it
truncates toward zero, wraps modulo 2^32, and answers 0 for NaN and for the infinities, where a
bare fptosi would be poison. And ** is ECMAScript exponentiation, which differs from the pow of
C99 in one corner.

The number functions of Math are emitted inline: an llvm intrinsic where this LLVM has one, a call
to libm otherwise.
*/

// build_binary emits an integer operation where opt narrowed one. It proved the result never leaves
// its type, which nsw tells LLVM, and a Remainder's dividend non-negative and its divisor never 0,
// where srem is what % computes.
@(private)
build_binary :: proc(m: ^Module, body: ^Body, v: ir.Binary, type: ir.Type) -> llvm.LLVMValueRef {
	left, right := body.values[v.left], body.values[v.right]
	integer := ir.is_integer(type)
	switch v.op {
	case .Add:
		if integer {
			return llvm.LLVMBuildNSWAdd(m.builder, left, right, "")
		}
		return llvm.LLVMBuildFAdd(m.builder, left, right, "")
	case .Subtract:
		if integer {
			return llvm.LLVMBuildNSWSub(m.builder, left, right, "")
		}
		return llvm.LLVMBuildFSub(m.builder, left, right, "")
	case .Multiply:
		if integer {
			return llvm.LLVMBuildNSWMul(m.builder, left, right, "")
		}
		return llvm.LLVMBuildFMul(m.builder, left, right, "")
	case .Divide:
		return llvm.LLVMBuildFDiv(m.builder, left, right, "")
	case .Remainder:
		if integer {
			return llvm.LLVMBuildSRem(m.builder, left, right, "")
		}
		if k, is_power := power_of_two(body.func.values[v.right]); is_power {
			return build_power_remainder(m, left, k)
		}
		// The remainder of a truncating division, which is what % means in ECMAScript.
		return llvm.LLVMBuildFRem(m.builder, left, right, "")
	case .Power:
		return build_power(m, left, right)
	case .Shift_Left:
		value := to_int32(m, body, v.left)
		shifted := llvm.LLVMBuildShl(m.builder, value, shift_count(m, body, v.right), "")
		return from_int32(m, shifted, type)
	case .Shift_Right:
		value := to_int32(m, body, v.left)
		shifted := llvm.LLVMBuildAShr(m.builder, value, shift_count(m, body, v.right), "")
		return from_int32(m, shifted, type)
	case .Shift_Right_Unsigned:
		// ToUint32 has the bits of ToInt32; only the way back to a number differs.
		value := to_int32(m, body, v.left)
		shifted := llvm.LLVMBuildLShr(m.builder, value, shift_count(m, body, v.right), "")
		return from_uint32(m, shifted, type)
	case .Bit_And:
		a, b := to_int32(m, body, v.left), to_int32(m, body, v.right)
		return from_int32(m, llvm.LLVMBuildAnd(m.builder, a, b, ""), type)
	case .Bit_Or:
		a, b := to_int32(m, body, v.left), to_int32(m, body, v.right)
		return from_int32(m, llvm.LLVMBuildOr(m.builder, a, b, ""), type)
	case .Bit_Xor:
		a, b := to_int32(m, body, v.left), to_int32(m, body, v.right)
		return from_int32(m, llvm.LLVMBuildXor(m.builder, a, b, ""), type)
	}
	unreachable()
}

// power_of_two answers k for a divisor that is the constant ±2^k, 0 <= k <= 1022, where 2^-k is
// still a normal number.
@(private)
power_of_two :: proc(divisor: ir.Instruction) -> (k: int, ok: bool) {
	constant, is_constant := divisor.variant.(ir.Const_Number)
	if !is_constant || divisor.type != ir.F64 {
		return 0, false
	}
	fraction, exponent := math.frexp(abs(constant.value))
	if fraction != 0.5 || exponent < 1 || exponent > 1023 {
		return 0, false
	}
	return exponent - 1, true
}

// build_power_remainder is x % ±2^k without a call to fmod. x - 2^k * trunc(x * 2^-k) is exact for
// every finite x: a scaling by a power of two, a truncation and that difference lose no bit. An
// infinity or NaN comes out NaN, as % answers. A difference of two equal values is +0, and copysign
// gives a negative x its -0 back: -4 % 2 is -0.
@(private)
build_power_remainder :: proc(m: ^Module, x: llvm.LLVMValueRef, k: int) -> llvm.LLVMValueRef {
	down := llvm.LLVMConstReal(m.types.double, math.ldexp(f64(1), -k))
	up := llvm.LLVMConstReal(m.types.double, math.ldexp(f64(1), k))
	scaled := [?]llvm.LLVMValueRef{llvm.LLVMBuildFMul(m.builder, x, down, "")}
	whole := build_number_call(m, .Trunc, scaled[:])
	multiple := llvm.LLVMBuildFMul(m.builder, whole, up, "")
	signs := [?]llvm.LLVMValueRef{llvm.LLVMBuildFSub(m.builder, x, multiple, ""), x}
	return build_double_call(m, "llvm.copysign", "copysign", signs[:])
}

// to_int32 is the ECMAScript ToInt32 of a value of any number type. An integer wraps modulo 2^32,
// which is what dropping its high bits does. A double is reduced in double, because fptosi is
// poison outside the range of an i32: after the two folds every finite input lands inside it, and
// what the reduction leaves of NaN and of an infinity is NaN, which the saturating conversion turns
// into the 0 the specification asks for.
@(private)
to_int32 :: proc(m: ^Module, body: ^Body, id: ir.Value_ID) -> llvm.LLVMValueRef {
	value := body.values[id]
	#partial switch body.func.values[id].type.kind {
	case .I32:
		return value
	case .I64:
		return llvm.LLVMBuildTrunc(m.builder, value, m.types.int32, "")
	}
	TWO_32 :: f64(4294967296)
	TWO_31 :: f64(2147483648)
	two_32 := llvm.LLVMConstReal(m.types.double, TWO_32)

	argument := [?]llvm.LLVMValueRef{value}
	truncated := build_number_call(m, .Trunc, argument[:])
	wrapped := llvm.LLVMBuildFRem(m.builder, truncated, two_32, "")

	above := llvm.LLVMBuildFCmp(
		m.builder,
		.LLVMRealOGE,
		wrapped,
		llvm.LLVMConstReal(m.types.double, TWO_31),
		"",
	)
	lowered := llvm.LLVMBuildFSub(m.builder, wrapped, two_32, "")
	folded := llvm.LLVMBuildSelect(m.builder, above, lowered, wrapped, "")

	below := llvm.LLVMBuildFCmp(
		m.builder,
		.LLVMRealOLT,
		folded,
		llvm.LLVMConstReal(m.types.double, -TWO_31),
		"",
	)
	raised := llvm.LLVMBuildFAdd(m.builder, folded, two_32, "")
	reduced := llvm.LLVMBuildSelect(m.builder, below, raised, folded, "")

	overloads := [?]llvm.LLVMTypeRef{m.types.int32, m.types.double}
	callee, found := intrinsic_function(m, "llvm.fptosi.sat", overloads[:])
	ensure(found, "this LLVM has no llvm.fptosi.sat intrinsic")
	saturated := [?]llvm.LLVMValueRef{reduced}
	return llvm.LLVMBuildCall2(
		m.builder,
		callee.signature,
		callee.function,
		&saturated[0],
		len(saturated),
		"",
	)
}

// from_int32 answers a 32 bit result as the result type of the operation, F64 or I32.
@(private)
from_int32 :: proc(m: ^Module, value: llvm.LLVMValueRef, type: ir.Type) -> llvm.LLVMValueRef {
	if type == ir.I32 {
		return value
	}
	return llvm.LLVMBuildSIToFP(m.builder, value, m.types.double, "")
}

// from_uint32 answers the result of an unsigned shift as F64 or I64: an I32 cannot hold it.
@(private)
from_uint32 :: proc(m: ^Module, value: llvm.LLVMValueRef, type: ir.Type) -> llvm.LLVMValueRef {
	if type == ir.I64 {
		return llvm.LLVMBuildZExt(m.builder, value, m.types.int64, "")
	}
	return llvm.LLVMBuildUIToFP(m.builder, value, m.types.double, "")
}

// A shift count is taken modulo 32, which is the low five bits of ToUint32 and of ToInt32 alike.
@(private)
shift_count :: proc(m: ^Module, body: ^Body, id: ir.Value_ID) -> llvm.LLVMValueRef {
	mask := llvm.LLVMConstInt(m.types.int32, 31, false)
	return llvm.LLVMBuildAnd(m.builder, to_int32(m, body, id), mask, "")
}

// build_power is ECMAScript exponentiation. It differs from the pow of C99 in one corner: with a
// base of 1 or -1 and an exponent that is NaN or an infinity, ECMAScript answers NaN where C
// answers 1. Every other pair agrees, so one select over that condition is the whole difference.
@(private)
build_power :: proc(m: ^Module, base, exponent: llvm.LLVMValueRef) -> llvm.LLVMValueRef {
	base_argument := [?]llvm.LLVMValueRef{base}
	unit_base := llvm.LLVMBuildFCmp(
		m.builder,
		.LLVMRealOEQ,
		build_number_call(m, .Abs, base_argument[:]),
		llvm.LLVMConstReal(m.types.double, 1),
		"",
	)
	exponent_argument := [?]llvm.LLVMValueRef{exponent}
	infinite := llvm.LLVMBuildFCmp(
		m.builder,
		.LLVMRealOEQ,
		build_number_call(m, .Abs, exponent_argument[:]),
		llvm.LLVMConstReal(m.types.double, math.inf_f64(1)),
		"",
	)
	// An unordered compare is true when an operand is NaN; against itself, that is exactly NaN.
	not_a_number := llvm.LLVMBuildFCmp(m.builder, .LLVMRealUNO, exponent, exponent, "")
	undefined := llvm.LLVMBuildOr(m.builder, infinite, not_a_number, "")
	special := llvm.LLVMBuildAnd(m.builder, unit_base, undefined, "")

	arguments := [?]llvm.LLVMValueRef{base, exponent}
	power := build_double_call(m, "llvm.pow", "pow", arguments[:])
	return llvm.LLVMBuildSelect(
		m.builder,
		special,
		llvm.LLVMConstReal(m.types.double, math.nan_f64()),
		power,
		"",
	)
}

// Number_Function leaves intrinsic empty when LLVM has none; libm is the symbol to call instead.
@(private)
Number_Function :: struct {
	intrinsic: string,
	libm:      string,
}

@(private, rodata)
NUMBER_FUNCTIONS := [ir.Intrinsic_Op]Number_Function {
	.Abs   = {"llvm.fabs", "fabs"},
	.Sqrt  = {"llvm.sqrt", "sqrt"},
	.Floor = {"llvm.floor", "floor"},
	.Ceil  = {"llvm.ceil", "ceil"},
	.Trunc = {"llvm.trunc", "trunc"},
	.Sin   = {"llvm.sin", "sin"},
	.Cos   = {"llvm.cos", "cos"},
	.Tan   = {"llvm.tan", "tan"},
	.Asin  = {"llvm.asin", "asin"},
	.Acos  = {"llvm.acos", "acos"},
	.Atan  = {"llvm.atan", "atan"},
	.Atan2 = {"llvm.atan2", "atan2"},
	.Sinh  = {"llvm.sinh", "sinh"},
	.Cosh  = {"llvm.cosh", "cosh"},
	.Tanh  = {"llvm.tanh", "tanh"},
	.Asinh = {"", "asinh"},
	.Acosh = {"", "acosh"},
	.Atanh = {"", "atanh"},
	.Exp   = {"llvm.exp", "exp"},
	.Expm1 = {"", "expm1"},
	.Log   = {"llvm.log", "log"},
	.Log1p = {"", "log1p"},
	.Log2  = {"llvm.log2", "log2"},
	.Log10 = {"llvm.log10", "log10"},
	.Cbrt  = {"", "cbrt"},
}

@(private)
build_number_call :: proc(
	m: ^Module,
	op: ir.Intrinsic_Op,
	args: []llvm.LLVMValueRef,
) -> llvm.LLVMValueRef {
	row := NUMBER_FUNCTIONS[op]
	return build_double_call(m, row.intrinsic, row.libm, args)
}

// build_double_call asks LLVM whether it knows the intrinsic rather than trusting the table, so a
// name that moves between LLVM versions falls back to libm instead of breaking the build.
@(private)
build_double_call :: proc(
	m: ^Module,
	intrinsic, libm: string,
	args: []llvm.LLVMValueRef,
) -> llvm.LLVMValueRef {
	callee, found := Function{}, false
	if intrinsic != "" {
		overloads := [?]llvm.LLVMTypeRef{m.types.double}
		callee, found = intrinsic_function(m, intrinsic, overloads[:])
	}
	if !found {
		callee = libm_function(m, libm, len(args))
	}
	return llvm.LLVMBuildCall2(
		m.builder,
		callee.signature,
		callee.function,
		raw_data(args),
		u32(len(args)),
		"",
	)
}

// intrinsic_function needs no cache: LLVM interns the declaration by its mangled name, so asking
// twice answers the same function.
@(private)
intrinsic_function :: proc(
	m: ^Module,
	name: string,
	overloads: []llvm.LLVMTypeRef,
) -> (
	Function,
	bool,
) {
	id := llvm.LLVMLookupIntrinsicID(raw_data(name), uint(len(name)))
	if id == 0 {
		return {}, false
	}
	count := uint(len(overloads))
	signature := llvm.LLVMIntrinsicGetType(m.ctx, id, raw_data(overloads), count)
	function := llvm.LLVMGetIntrinsicDeclaration(m.module, id, raw_data(overloads), count)
	return {signature, function}, true
}

@(private)
libm_function :: proc(m: ^Module, symbol: string, arity: int) -> Function {
	if declared, found := m.libm[symbol]; found {
		return declared
	}
	params := make([]llvm.LLVMTypeRef, arity, context.temp_allocator)
	for i in 0 ..< arity {
		params[i] = m.types.double
	}
	signature := llvm.LLVMFunctionType(m.types.double, raw_data(params), u32(arity), false)
	name := strings.clone_to_cstring(symbol, context.temp_allocator)
	function := Function{signature, llvm.LLVMAddFunction(m.module, name, signature)}
	m.libm[symbol] = function
	return function
}
