package lower_tests

import "core:testing"

import "../../src/ir"

// Control flow. The done criterion of T4.3 is that the IR of a program with loops and a switch
// passes the verifier, which lower_sources asserts for every program here; what each test adds is
// the shape it expects, so that a loop quietly losing its back edge would still fail.

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
