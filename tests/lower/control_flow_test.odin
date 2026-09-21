package lower_tests

import "core:slice"
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
a_never_arm_of_a_ternary_is_no_edge_of_the_join :: proc(t: ^testing.T) {
	// The arm that exits ends unreachable, so the join has one edge and the value is the other arm
	// as it is: no phi, and the `return` hands back the parameter itself.
	result := lower_text(
		t,
		`
		function f(n: number): number {
			return n > 0 ? n : process.exit(70);
		}
		function die(c: number): never {
			process.exit(c);
		}
		function g(n: number): number {
			const x: number = n > 0 ? n * 2 : die(72);
			return x + 1;
		}
		f(2);
		g(2);
		`,
	)
	f, found_f := func_named(result.output, "m1.f")
	testing.expect(t, found_f, "f was not lowered")
	testing.expectf(t, count_of(f, ir.Phi) == 0, "%s", result.text)
	testing.expectf(t, slice.equal(returned(f), []ir.Value_ID{0}), "%s", result.text)

	// The declarator used to skip its store when the never arm came back as poison, and `x + 1`
	// read the zero x was given when the body opened.
	g, found_g := func_named(result.output, "m1.g")
	testing.expect(t, found_g, "g was not lowered")
	testing.expectf(t, count_of(g, ir.Phi) == 0, "%s", result.text)
	sum := g.values[returned(g)[0]].variant.(ir.Binary)
	_, doubled := g.values[sum.left].variant.(ir.Binary)
	testing.expectf(t, doubled, "x + 1 does not read n * 2:\n%s", result.text)
}

@(test)
a_ternary_whose_arms_both_never_return_joins_nothing :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function f(c: boolean): number {
			return c ? process.exit(1) : process.exit(2);
		}
		function g(c: boolean): void {
			c ? process.exit(3) : process.exit(4);
			console.log("never");
		}
		f(true);
		g(true);
		`,
	)
	f, found_f := func_named(result.output, "m1.f")
	testing.expect(t, found_f, "f was not lowered")
	testing.expectf(t, count_of(f, ir.Phi) == 0, "%s", result.text)
	testing.expectf(t, len(returned(f)) == 0, "%s", result.text)

	// What follows the statement is code no edge reaches, and the verifier accepts it as such.
	g, found_g := func_named(result.output, "m1.g")
	testing.expect(t, found_g, "g was not lowered")
	testing.expectf(t, count_of(g, ir.Phi) == 0, "%s", result.text)
}

@(test)
a_never_right_side_of_a_short_circuit_leaves_the_left_one :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function f(n: number): number {
			n > 0 || process.exit(71);
			n < 100 && process.exit(72);
			return n;
		}
		function g(n: number): boolean {
			return n > 0 || process.exit(73);
		}
		f(2);
		g(2);
		`,
	)
	f, found_f := func_named(result.output, "m1.f")
	testing.expect(t, found_f, "f was not lowered")
	testing.expectf(t, count_of(f, ir.Phi) == 0, "%s", result.text)
	testing.expectf(t, slice.equal(returned(f), []ir.Value_ID{0}), "%s", result.text)

	g, found_g := func_named(result.output, "m1.g")
	testing.expect(t, found_g, "g was not lowered")
	testing.expectf(t, count_of(g, ir.Phi) == 0, "%s", result.text)
	_, compared := g.values[returned(g)[0]].variant.(ir.Compare)
	testing.expectf(t, compared, "g does not return n > 0:\n%s", result.text)
}

@(test)
a_ternary_or_short_circuit_statement_joins_no_value :: proc(t: ^testing.T) {
	// Nobody reads the value of a statement, so the two sides need not share a representation:
	// two void calls, or a boolean and a number, meet without a phi of their own. The only phi
	// left is the local the assignment wrote on one side.
	result := lower_text(
		t,
		`
		function v(): void {}
		function f(c: boolean): void {
			c ? v() : v();
			c && console.log("x");
		}
		function g(c: boolean): number {
			let x = 1;
			c && (x = 5);
			return x;
		}
		f(true);
		g(true);
		`,
	)
	f, found_f := func_named(result.output, "m1.f")
	testing.expect(t, found_f, "f was not lowered")
	testing.expectf(t, count_of(f, ir.Phi) == 0, "%s", result.text)

	g, found_g := func_named(result.output, "m1.g")
	testing.expect(t, found_g, "g was not lowered")
	testing.expectf(t, count_of(g, ir.Phi) == 1, "%s", result.text)
	_, is_phi := g.values[returned(g)[0]].variant.(ir.Phi)
	testing.expectf(t, is_phi, "g does not return the joined x:\n%s", result.text)
}

@(test)
a_void_call_returned_as_a_tagged_value_is_undefined :: proc(t: ^testing.T) {
	result := lower_text(
		t,
		`
		function v(): void {}
		function g(): number | void {
			return v();
		}
		g();
		`,
	)
	g, found := func_named(result.output, "m1.g")
	testing.expect(t, found, "g was not lowered")
	testing.expectf(t, len(returned(g)) == 1, "%s", result.text)
	_, is_undefined := g.values[returned(g)[0]].variant.(ir.Const_Undefined)
	testing.expectf(t, is_undefined, "%s", result.text)
}

@(test)
poison_nothing_reported_is_named_at_the_expression :: proc(t: ^testing.T) {
	// process.exit answers no value, and the `!` that reads it answers poison without a word.
	// The net in lower_expression names the `!`, so the build fails instead of compiling it.
	expect_later(t, "const b = !process.exit(3);\n", {{.Not_Lowered, 1, 11}})
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

// returned lists the value of every `return` of a function that returns one, in value order.
@(private = "file")
returned :: proc(body: ir.Func) -> []ir.Value_ID {
	out := make([dynamic]ir.Value_ID, context.temp_allocator)
	for instruction in body.values {
		if leave, is_return := instruction.variant.(ir.Return); is_return {
			append(&out, leave.value)
		}
	}
	return out[:]
}

// count_of counts the IR rather than the dump, which keeps a test from breaking when the printer
// changes a word.
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
