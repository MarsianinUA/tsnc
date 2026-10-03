package opt_tests

import "core:testing"

import "../../src/ir"
import "../harness"

// tests/diff/src/integers.ts shows that the narrowed programs print what Node prints.

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
	init := harness.func_named(t, result.output, "init$m1")
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
	init := harness.func_named(t, result.output, "init$m1")
	phi, _, found := counter(init)
	testing.expectf(t, found && init.values[phi].type == ir.I64, "%s", result.after)
}

// Both stand on abi.MAX_ARRAY_LENGTH: with a length bounded only by 2^53 - 1, `length + 1` and
// `lo + hi` stay F64.
@(test)
the_length_a_push_writes_is_an_integer_add :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		const values: number[] = [];
		for (let i = 0; i < 10; i++) {
			values.push(i);
		}
		console.log(values.length);
	`,
	)
	init := harness.func_named(t, result.output, "init$m1")
	_, sets := instructions_of(init, ir.Set_Length)
	if !testing.expectf(t, len(sets) == 1, "%s", result.after) {
		return
	}
	add, is_binary := init.values[sets[0].length].variant.(ir.Binary)
	testing.expectf(t, is_binary && add.op == .Add, "%s", result.after)
	testing.expectf(t, init.values[sets[0].length].type == ir.I64, "%s", result.after)
}

@(test)
the_sum_of_two_indices_stays_an_integer :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		function find(a: number[], key: number): number {
			let lo = 0;
			let hi = a.length - 1;
			while (lo <= hi) {
				const mid = (lo + hi) >> 1;
				if (a[mid] === key) {
					return mid;
				}
				if (a[mid] < key) {
					lo = mid + 1;
				} else {
					hi = mid - 1;
				}
			}
			return -1;
		}
		console.log(find([1, 3, 5], 5));
	`,
	)
	find := harness.func_named(t, result.output, "m1.find")
	_, binaries := instructions_of(find, ir.Binary)
	summed := false
	for binary in binaries {
		if binary.op != .Shift_Right {
			continue
		}
		add, is_binary := find.values[binary.left].variant.(ir.Binary)
		summed = is_binary && add.op == .Add && find.values[binary.left].type == ir.I64
	}
	testing.expectf(t, summed, "%s", result.after)
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
	collatz := harness.func_named(t, result.output, "m1.collatz")
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
	init := harness.func_named(t, result.output, "init$m1")
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
	init := harness.func_named(t, result.output, "init$m1")
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
	init := harness.func_named(t, result.output, "init$m1")
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
	// mix is inlined into the module's init.
	mix := harness.func_named(t, result.output, "init$m1")
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
	next := harness.func_named(t, result.output, "m1.next")
	ids, binaries := instructions_of(next, ir.Binary)
	found := false
	for binary, i in binaries {
		if binary.op == .Remainder {
			found = next.values[ids[i]].type == ir.I64
		}
	}
	testing.expectf(t, found, "%s", result.after)
}

// A closure call reaches every function value with its kinds of parameters, so a fraction one of
// them takes reaches the others.
@(test)
a_parameter_narrows_from_every_call_its_class_takes :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		// A loop keeps direct a call.
		function direct(n: number): number {
			let twice = n + n;
			for (let j = 0; j < 2; j++) {
				twice += j;
			}
			return twice;
		}
		function held(n: number): number {
			return n + n;
		}
		function scaled(n: number, k: number): number {
			return n * k;
		}
		function other(n: number, k: number): number {
			return n - k;
		}
		const f = held;
		const s = scaled;
		const o = other;
		for (let i = 0; i < 10; i++) {
			console.log(direct(i), held(i), f(i), scaled(i, 2), o(i, 0.5), s === o);
		}
	`,
	)
	for c in ([3]struct {
			name: string,
			want: ir.Type,
		}{{"m1.direct", ir.I32}, {"m1.held", ir.I32}, {"m1.scaled", ir.F64}}) {
		body := harness.func_named(t, result.output, c.name)
		ids, binaries := instructions_of(body, ir.Binary)
		testing.expectf(t, body.values[ids[0]].type == c.want, "%s:\n%s", c.name, result.after)
		// A parameter arrives as F64 and is read as an integer through a conversion.
		testing.expectf(t, read_as(body, binaries[0].left) == 0, "%s:\n%s", c.name, result.after)
	}
}

@(test)
a_field_every_store_keeps_whole_is_an_integer :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		interface Counter {
			n: number;
			step: number;
		}
		function main(): void {
			const c: Counter = { n: 0, step: 3 };
			const hist: number[] = [0, 0, 0, 0, 0, 0, 0, 0];
			for (let i = 0; i < 100; i++) {
				c.n = (c.n + c.step) % 8;
				hist[c.n] += 1;
			}
			console.log(hist.join(","));
		}
		main();
	`,
	)
	body := harness.func_named(t, result.output, "m1.main")
	ids, binaries := instructions_of(body, ir.Binary)
	remainders := 0
	for binary, i in binaries {
		if binary.op == .Remainder {
			remainders += 1
			testing.expectf(t, ir.is_integer(body.values[ids[i]].type), "%s", result.after)
		}
	}
	testing.expectf(t, remainders == 1, "%s", result.after)
	ids, _ = instructions_of(body, ir.Bounds_Check)
	for id in ids {
		testing.expectf(t, ir.is_integer(body.values[id].type), "%s", result.after)
	}
}

@(test)
an_element_every_store_keeps_whole_is_an_integer :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		function main(): void {
			const a: number[] = [];
			for (let i = 0; i < 10; i++) {
				a.push(i & 255);
			}
			let h = 0;
			for (let i = 0; i < a.length; i++) {
				h = h + a[i] * 3;
			}
			console.log(h);
		}
		main();
	`,
	)
	body := harness.func_named(t, result.output, "m1.main")
	ids, binaries := instructions_of(body, ir.Binary)
	found := false
	for binary, i in binaries {
		if binary.op != .Multiply {
			continue
		}
		_, is_load := body.values[read_as(body, binary.left)].variant.(ir.Element_Load)
		found ||= is_load && body.values[ids[i]].type == ir.I32
	}
	testing.expectf(t, found, "no I32 product of an element:\n%s", result.after)
}

@(test)
one_fraction_stored_through_any_place_of_a_layout_keeps_its_field_f64 :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		interface Point {
			x: number;
			y: number;
		}
		function shift(p: Point): void {
			p.x = p.x + 0.5;
		}
		function main(): void {
			const p: Point = { x: 1, y: 2 };
			// A write after a read keeps p a cell.
			p.y = p.y % 3;
			const q: Point = { x: 3, y: 4 };
			shift(q);
			console.log(p.x * 2, p.y * 2);
		}
		main();
	`,
	)
	body := harness.func_named(t, result.output, "m1.main")
	ids, binaries := instructions_of(body, ir.Binary)
	seen := 0
	for binary, i in binaries {
		load, is_load := body.values[read_as(body, binary.left)].variant.(ir.Field_Load)
		if binary.op != .Multiply || !is_load {
			continue
		}
		seen += 1
		want := ir.F64 if load.field == 0 else ir.I32
		testing.expectf(
			t,
			body.values[ids[i]].type == want,
			"field %d:\n%s",
			load.field,
			result.after,
		)
	}
	testing.expectf(t, seen == 2, "%s", result.after)
}

// The runtime calls a comparator with the elements of the array it sorts.
@(test)
a_comparator_reads_whole_elements_as_integers :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		const a: number[] = [];
		for (let i = 0; i < 10; i++) {
			a.push((i * 7) % 10);
		}
		a.sort((x, y) => x - y);
		console.log(a);
	`,
	)
	found := false
	for body in result.output.funcs {
		ids, binaries := instructions_of(body, ir.Binary)
		if len(body.params) == 2 && len(binaries) == 1 && binaries[0].op == .Subtract {
			found ||= body.values[ids[0]].type == ir.I32
		}
	}
	testing.expectf(t, found, "no I32 difference in the comparator:\n%s", result.after)
}
