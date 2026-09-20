package lower_tests

import "core:testing"

import "../../src/ir"

// Control flow. The done criterion of T4.3 is that the IR of a program with loops and a switch
// passes the verifier, which lower_sources asserts for every program here; what each test adds is
// the shape it expects, so that a loop quietly losing its back edge would still fail.

@(test)
while_loop_over_module_globals :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		let total = 0;
		let i = 0;
		while (i < 10) {
			total = total + i;
			i = i + 1;
		}
		console.log(total);
		`,
	)
	body, found := func_named(result.output, "init$m1")
	testing.expect(t, found, "the module has no init function")
	// A module binding is a cell of the program, so the loop carries nothing through a phi: it
	// loads and stores the two globals instead. Six stores: the two zeroes the module opens with,
	// the two initializers, and the two the loop body writes.
	testing.expectf(t, count_of(body, ir.Phi) == 0, "%s", result.text)
	testing.expectf(t, count_of(body, ir.Global_Store) == 6, "%s", result.text)
	testing.expectf(t, count_of(body, ir.Branch) == 1, "%s", result.text)
}

@(test)
a_local_written_in_a_loop_becomes_a_phi :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function sum(n: number): number {
			let total = 0;
			let i = 0;
			while (i < n) {
				total = total + i;
				i = i + 1;
			}
			return total;
		}
		sum(3);
		`,
	)
	body, found := func_named(result.output, "m1.sum")
	testing.expect(t, found, "the function was not lowered")
	// One header phi for each of the two locals the loop writes, and none for the parameter.
	testing.expectf(t, count_of(body, ir.Phi) == 2, "%s", result.text)
}

@(test)
for_loop_with_break_and_continue :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function count(n: number): number {
			let seen = 0;
			for (let i = 0; i < n; i = i + 1) {
				if (i === 3) {
					continue;
				}
				if (i === 7) {
					break;
				}
				seen = seen + 1;
			}
			return seen;
		}
		count(10);
		`,
	)
	body, found := func_named(result.output, "m1.count")
	testing.expect(t, found, "the function was not lowered")
	testing.expectf(t, count_of(body, ir.Phi) >= 2, "%s", result.text)
}

@(test)
do_while_runs_its_body_first :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function first(n: number): number {
			let i = 0;
			do {
				i = i + 1;
			} while (i < n);
			return i;
		}
		first(0);
		`,
	)
	body, found := func_named(result.output, "m1.first")
	testing.expect(t, found, "the function was not lowered")
	testing.expectf(t, count_of(body, ir.Phi) == 1, "%s", result.text)
}

@(test)
a_loop_whose_body_always_returns_leaves_nothing_after_it :: proc(t: ^testing.T) {
	// Nothing reaches the latch, the condition or the exit, so the blocks the loop opened all end
	// in an inert terminator and the statement after the loop still has a block of its own.
	lower_text(
		t,
		`
		function once(n: number): number {
			do {
				return n;
			} while (n > 0);
		}
		once(1);
		`,
	)
	lower_text(
		t,
		`
		function twice(n: number): number {
			while (n > 0) {
				return n;
			}
			return 0;
		}
		twice(1);
		`,
	)
}

@(test)
nested_loops_break_the_inner_one :: proc(t: ^testing.T) {
	lower_text(
		t,
		`
		function grid(n: number): number {
			let total = 0;
			for (let y = 0; y < n; y = y + 1) {
				for (let x = 0; x < n; x = x + 1) {
					if (x > y) {
						break;
					}
					total = total + 1;
				}
			}
			return total;
		}
		grid(4);
		`,
	)
}

@(test)
switch_falls_through_and_defaults :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function name(kind: number): number {
			let out = 0;
			switch (kind) {
			case 1:
			case 2:
				out = 12;
				break;
			case 3:
				out = 3;
			default:
				out = out + 100;
			}
			return out;
		}
		name(2);
		`,
	)
	body, found := func_named(result.output, "m1.name")
	testing.expect(t, found, "the function was not lowered")
	// One comparison per case value, and none for the default.
	testing.expectf(t, count_of(body, ir.Compare) == 3, "%s", result.text)
}

@(test)
switch_inside_a_loop_lets_continue_through :: proc(t: ^testing.T) {
	lower_text(
		t,
		`
		function pick(n: number): number {
			let total = 0;
			for (let i = 0; i < n; i = i + 1) {
				switch (i) {
				case 0:
					continue;
				case 1:
					break;
				default:
					total = total + i;
				}
				total = total + 1;
			}
			return total;
		}
		pick(5);
		`,
	)
}

@(test)
ternary_and_short_circuit_join_in_a_phi :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function pick(a: number, b: number, flag: boolean): number {
			const bigger = a > b ? a : b;
			const ok = flag && a > 0;
			const any = flag || b > 0;
			return ok && any ? bigger : 0;
		}
		pick(1, 2, true);
		`,
	)
	body, found := func_named(result.output, "m1.pick")
	testing.expect(t, found, "the function was not lowered")
	// One join per `?:`, per `&&` and per `||`.
	testing.expectf(t, count_of(body, ir.Phi) == 5, "%s", result.text)
}

@(test)
an_early_return_leaves_the_rest_unreachable :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function sign(x: number): number {
			if (x > 0) {
				return 1;
			}
			return -1;
		}
		sign(2);
		`,
	)
	body, found := func_named(result.output, "m1.sign")
	testing.expect(t, found, "the function was not lowered")
	testing.expectf(t, count_of(body, ir.Return) == 2, "%s", result.text)
}

@(test)
every_arithmetic_and_bitwise_operator_lowers :: proc(t: ^testing.T) {
	lower_text(
		t,
		`
		function all(a: number, b: number): number {
			let r = a + b - a * b / a % b;
			r = r ** 2;
			r = (r | 0) & 0xff ^ 3;
			r = (r << 2) >> 1;
			r = r >>> 1;
			r = -r;
			r = ~r;
			r += 1;
			r -= 1;
			r *= 2;
			r /= 2;
			r++;
			r--;
			return r;
		}
		all(6, 3);
		`,
	)
}

@(test)
a_number_is_truthy_when_its_magnitude_is_above_zero :: proc(t: ^testing.T) {
	// The test is one intrinsic and one comparison, which is false for NaN and for both zeros.
	result := lower_text(
		t,
		`
		function pick(n: number): number {
			if (n) {
				return 1;
			}
			return !n ? 2 : 3;
		}
		pick(0);
		`,
	)
	body, found := func_named(result.output, "m1.pick")
	testing.expect(t, found, "the function was not lowered")
	sizes := 0
	for instruction in body.values {
		if call, is_call := instruction.variant.(ir.Intrinsic); is_call && call.op == .Abs {
			sizes += 1
		}
	}
	testing.expectf(t, sizes == 2, "%s", result.text)
}

@(test)
a_void_function_returns_nothing :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function announce(n: number): void {
			if (n > 0) {
				return;
			}
			console.log(n);
		}
		announce(1);
		`,
	)
	body, found := func_named(result.output, "m1.announce")
	testing.expect(t, found, "the function was not lowered")
	testing.expect(t, body.result == ir.VOID)
	for instruction in body.values {
		if leave, is_return := instruction.variant.(ir.Return); is_return {
			testing.expectf(t, leave.value == ir.NO_VALUE, "%s", result.text)
		}
	}
}

@(test)
a_return_inside_a_switch_inside_a_loop :: proc(t: ^testing.T) {
	lower_text(
		t,
		`
		function find(n: number): number {
			while (true) {
				switch (n) {
				case 0:
					return 10;
				default:
					n = n - 1;
				}
			}
		}
		find(3);
		`,
	)
}

@(test)
the_dump_is_the_same_every_time :: proc(t: ^testing.T) {
	text := `
		function fib(n: number): number {
			let a = 0;
			let b = 1;
			for (let i = 0; i < n; i = i + 1) {
				const next = a + b;
				a = b;
				b = next;
			}
			return a;
		}
		console.log(fib(10));
		`
	first := lower_text(t, text)
	second := lower_text(t, text)
	testing.expect(t, first.text == second.text, "two runs of one program gave two dumps")
}

// count_of is how many instructions of one kind a function holds. Counting the IR rather than the
// dump keeps a test from breaking when the printer changes a word.
@(private = "file")
count_of :: proc(body: ir.Func, $Variant: typeid) -> int {
	total := 0
	for instruction in body.values {
		if _, is_kind := instruction.variant.(Variant); is_kind {
			total += 1
		}
	}
	return total
}
