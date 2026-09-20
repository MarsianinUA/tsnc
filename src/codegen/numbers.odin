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

@(private)
build_binary :: proc(m: ^Module, body: ^Body, v: ir.Binary) -> llvm.LLVMValueRef {
	left, right := body.values[v.left], body.values[v.right]
	switch v.op {
	case .Add:
		return llvm.LLVMBuildFAdd(m.builder, left, right, "")
	case .Subtract:
		return llvm.LLVMBuildFSub(m.builder, left, right, "")
	case .Multiply:
		return llvm.LLVMBuildFMul(m.builder, left, right, "")
	case .Divide:
		return llvm.LLVMBuildFDiv(m.builder, left, right, "")
	case .Remainder:
		// The remainder of a truncating division, which is what % means in ECMAScript.
		return llvm.LLVMBuildFRem(m.builder, left, right, "")
	case .Power:
		return build_power(m, left, right)
	case .Shift_Left:
		return from_int32(
			m,
			llvm.LLVMBuildShl(m.builder, to_int32(m, left), shift_count(m, right), ""),
		)
	case .Shift_Right:
		return from_int32(
			m,
			llvm.LLVMBuildAShr(m.builder, to_int32(m, left), shift_count(m, right), ""),
		)
	case .Shift_Right_Unsigned:
		// ToUint32 has the bits of ToInt32; only the way back to a double differs.
		return from_uint32(
			m,
			llvm.LLVMBuildLShr(m.builder, to_int32(m, left), shift_count(m, right), ""),
		)
	case .Bit_And:
		return from_int32(
			m,
			llvm.LLVMBuildAnd(m.builder, to_int32(m, left), to_int32(m, right), ""),
		)
	case .Bit_Or:
		return from_int32(
			m,
			llvm.LLVMBuildOr(m.builder, to_int32(m, left), to_int32(m, right), ""),
		)
	case .Bit_Xor:
		return from_int32(
			m,
			llvm.LLVMBuildXor(m.builder, to_int32(m, left), to_int32(m, right), ""),
		)
	}
	unreachable()
}

@(private)
build_bit_not :: proc(m: ^Module, operand: llvm.LLVMValueRef) -> llvm.LLVMValueRef {
	return from_int32(m, llvm.LLVMBuildNot(m.builder, to_int32(m, operand), ""))
}

// to_int32 is the ECMAScript ToInt32. The reduction happens in double, because fptosi is poison
// outside the range of an i32: after the two folds every finite input lands inside it, and what the
// reduction leaves of NaN and of an infinity is NaN, which the saturating conversion turns into the
// 0 the specification asks for.
@(private)
to_int32 :: proc(m: ^Module, value: llvm.LLVMValueRef) -> llvm.LLVMValueRef {
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

@(private)
from_int32 :: proc(m: ^Module, value: llvm.LLVMValueRef) -> llvm.LLVMValueRef {
	return llvm.LLVMBuildSIToFP(m.builder, value, m.types.double, "")
}

@(private)
from_uint32 :: proc(m: ^Module, value: llvm.LLVMValueRef) -> llvm.LLVMValueRef {
	return llvm.LLVMBuildUIToFP(m.builder, value, m.types.double, "")
}

// A shift count is taken modulo 32, which is the low five bits of ToUint32 and of ToInt32 alike.
@(private)
shift_count :: proc(m: ^Module, value: llvm.LLVMValueRef) -> llvm.LLVMValueRef {
	mask := llvm.LLVMConstInt(m.types.int32, 31, false)
	return llvm.LLVMBuildAnd(m.builder, to_int32(m, value), mask, "")
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

// Number_Function is how one number function is emitted: the llvm intrinsic that inlines it, empty
// when LLVM has none, and the libm symbol to call instead.
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

// build_double_call calls a function of doubles that answers a double: the intrinsic when this LLVM
// knows the name, a libm call otherwise. Asking LLVM rather than trusting the table means a name
// that moves between LLVM versions falls back to libm instead of breaking the build.
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

// intrinsic_function declares one overload of an LLVM intrinsic. LLVM interns the declaration by
// its mangled name, so asking twice answers the same function and no cache is needed.
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

// libm_function declares a C library function of doubles, once per module.
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
