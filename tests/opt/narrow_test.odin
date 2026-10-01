package opt_tests

import "core:testing"

import "../../src/ir"

// Integer narrowing: which numbers become I32 or I64 and which stay F64. tests/diff/src/integers.ts
// shows that the narrowed programs print what Node prints.

@(test)
a_counter_bounded_by_a_constant_global_is_i32 :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		const LIMIT = 1000;
		let total = 0;
		for (let i = 0; i < LIMIT; i++) {
			total += i;
		}
		console.log(total);
	`,
	)
	init := func_named(result.output, "init$m1")
	phi, step, found := counter(init)
	if !testing.expectf(t, found, "%s", result.after) {
		return
	}
	testing.expectf(t, init.values[phi].type == ir.I32, "%s", result.after)
	testing.expectf(t, init.values[step].type == ir.I32, "%s", result.after)
	_, compares := instructions_of(init, ir.Compare)
	compared := false
	for compare in compares {
		if compare.op == .Less && compare.left == phi {
			compared = init.values[compare.right].type == ir.I32
		}
	}
	testing.expectf(t, compared, "no I32 comparison of the counter:\n%s", result.after)
}

@(test)
a_counter_below_a_length_is_i64 :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		const values: number[] = [1, 2, 3];
		let sum = 0;
		for (let i = 0; i < values.length; i++) {
			sum += values[i];
		}
		console.log(sum);
	`,
	)
	init := func_named(result.output, "init$m1")
	phi, _, found := counter(init)
	testing.expectf(t, found && init.values[phi].type == ir.I64, "%s", result.after)
}

@(test)
what_no_bound_holds_stays_f64 :: proc(t: ^testing.T) {
	// steps has no bound, and x = 3x + 1 is the Collatz problem: nothing proves it stays small.
	result := optimize_text(
		t,
		`
		function collatz(start: number): number {
			let x = start;
			let steps = 0;
			while (x !== 1) {
				x = x % 2 === 0 ? x / 2 : 3 * x + 1;
				steps++;
			}
			return steps;
		}
		console.log(collatz(27));
	`,
	)
	collatz := func_named(result.output, "m1.collatz")
	phi, _, found := counter(collatz)
	testing.expectf(t, found && collatz.values[phi].type == ir.F64, "%s", result.after)
	_, products := instructions_of(collatz, ir.Binary)
	for product in products {
		if product.op == .Multiply {
			testing.expectf(t, collatz.values[product.right].type == ir.F64, "%s", result.after)
		}
	}
}

@(test)
a_value_past_2_to_the_53_stays_f64 :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		for (let i = 9007199254740980; i < 9007199254741000; i++) {
			console.log(i);
		}
	`,
	)
	init := func_named(result.output, "init$m1")
	phi, _, found := counter(init)
	testing.expectf(t, found && init.values[phi].type == ir.F64, "%s", result.after)
}

@(test)
a_negation_that_may_be_minus_zero_stays_f64 :: proc(t: ^testing.T) {
	result := optimize_text(t, `
		for (let i = 0; i < 10; i++) {
			console.log(-i);
		}
	`)
	init := func_named(result.output, "init$m1")
	phi, _, _ := counter(init)
	ids, unaries := instructions_of(init, ir.Unary)
	negated := false
	for unary, i in unaries {
		if unary.op == .Negate && read_as(init, unary.operand) == phi {
			negated = init.values[ids[i]].type == ir.F64
		}
	}
	testing.expectf(t, negated && init.values[phi].type == ir.I32, "%s", result.after)
}

@(test)
a_remainder_is_an_integer_only_of_a_dividend_that_is_never_negative :: proc(t: ^testing.T) {
	// x % 2 of a negative x may be -0, which no integer holds.
	result := optimize_text(
		t,
		`
		let sum = 0;
		for (let i = 0; i < 100; i++) {
			sum += i % 7;
		}
		for (let x = -50; x < 50; x++) {
			sum += x % 2;
		}
		console.log(sum);
	`,
	)
	init := func_named(result.output, "init$m1")
	ids, binaries := instructions_of(init, ir.Binary)
	kinds: bit_set[ir.Type_Kind]
	for binary, i in binaries {
		if binary.op != .Remainder {
			continue
		}
		divisor := init.values[binary.right].variant.(ir.Const_Number)
		want := ir.I32 if divisor.value == 7 else ir.F64
		testing.expectf(t, init.values[ids[i]].type == want, "%v:\n%s", divisor, result.after)
		kinds += {init.values[ids[i]].type.kind}
	}
	testing.expectf(t, kinds == {.I32, .F64}, "%s", result.after)
}

@(test)
a_bitwise_result_feeds_the_next_bitwise_operator_as_it_is :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		function mix(a: number, b: number): number {
			return ((a / b) | 0) & 255;
		}
		console.log(mix(7, 2));
	`,
	)
	mix := func_named(result.output, "m1.mix")
	ids, binaries := instructions_of(mix, ir.Binary)
	anded := false
	for binary, i in binaries {
		if binary.op != .Bit_And {
			continue
		}
		or, is_binary := mix.values[binary.left].variant.(ir.Binary)
		anded = is_binary && or.op == .Bit_Or
		anded &&= mix.values[binary.left].type == ir.I32 && mix.values[ids[i]].type == ir.I32
	}
	testing.expectf(t, anded, "%s", result.after)
}

@(test)
a_global_the_program_keeps_below_2_to_the_31_is_an_integer :: proc(t: ^testing.T) {
	// The seed of Park and Miller's generator: every store is a remainder by 2^31 - 1, and the
	// product before it needs 64 bits.
	result := optimize_text(
		t,
		`
		let seed = 11;
		function next(): number {
			seed = (seed * 16807) % 2147483647;
			return seed;
		}
		console.log(next(), next());
	`,
	)
	next := func_named(result.output, "m1.next")
	ids, binaries := instructions_of(next, ir.Binary)
	found := false
	for binary, i in binaries {
		if binary.op == .Remainder {
			found = next.values[ids[i]].type == ir.I64
		}
	}
	testing.expectf(t, found, "%s", result.after)
}

@(test)
only_a_parameter_of_a_function_called_directly_narrows :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		function direct(n: number): number {
			return n + n;
		}
		function held(n: number): number {
			return n + n;
		}
		const f = held;
		for (let i = 0; i < 10; i++) {
			console.log(direct(i), held(i), f(i));
		}
	`,
	)
	for c in ([2]struct {
			name: string,
			want: ir.Type,
		}{{"m1.direct", ir.I32}, {"m1.held", ir.F64}}) {
		body := func_named(result.output, c.name)
		ids, binaries := instructions_of(body, ir.Binary)
		testing.expectf(t, body.values[ids[0]].type == c.want, "%s:\n%s", c.name, result.after)
		// A parameter arrives as F64 and is read as an integer through a conversion.
		testing.expectf(t, read_as(body, binaries[0].left) == 0, "%s:\n%s", c.name, result.after)
	}
}
