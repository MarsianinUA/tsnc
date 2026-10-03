package opt_tests

import "core:testing"

import "../../src/ir"
import "../harness"

// The checks that stay fail where they should in tests/expect/array-shrink.ts.

@(test)
a_check_below_the_length_the_loop_tested_is_proved :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		function sum(values: number[]): number {
			let total = 0;
			for (let i = 0; i < values.length; i++) {
				total += values[i];
			}
			for (const value of values) {
				total += value;
			}
			return total;
		}
		console.log(sum([1, 2, 3]));
	`,
	)
	sum := harness.func_named(t, result.output, "m1.sum")
	checks, proved := check_counts(sum)
	testing.expectf(t, checks == 0 && proved == 2, "%s", result.after)
}

@(test)
a_string_is_never_shortened_by_a_call :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		function spell(text: string): void {
			for (const c of text) {
				console.log(c);
			}
			for (let i = 0; i < text.length; i++) {
				console.log(text[i]);
			}
		}
		spell("abc");
	`,
	)
	spell := harness.func_named(t, result.output, "m1.spell")
	checks, proved := check_counts(spell)
	testing.expectf(t, checks == 0 && proved == 2, "%s", result.after)
}

@(test)
the_elements_of_an_array_literal_are_proved :: proc(t: ^testing.T) {
	// A call before the array exists stands on no path from it to its stores.
	result := optimize_text(
		t,
		`
		function three(n: number): number[] {
			console.log(n);
			return [n, n + 1, n + 2];
		}
		console.log(three(1));
	`,
	)
	three := harness.func_named(t, result.output, "m1.three")
	checks, proved := check_counts(three)
	testing.expectf(t, checks == 0 && proved == 3, "%s", result.after)
}

@(test)
the_store_of_a_compound_assignment_reuses_the_check_of_its_read :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		// The call to itself keeps bump a call.
		function bump(values: number[], i: number): void {
			values[i] += 1;
			if (i > 0) {
				bump(values, i - 1);
			}
		}
		const values = [1, 2];
		bump(values, 1);
		console.log(values);
	`,
	)
	bump := harness.func_named(t, result.output, "m1.bump")
	checks, proved := check_counts(bump)
	ids, all := instructions_of(bump, ir.Bounds_Check)
	testing.expectf(t, checks == 1 && proved == 1, "%s", result.after)
	for check, i in all {
		if !check.proved || lower_proved(check) {
			continue
		}
		_, reads_the_check := bump.values[check.index].variant.(ir.Bounds_Check)
		testing.expectf(t, reads_the_check, "%v:\n%s", ids[i], result.after)
	}
}

@(test)
a_check_stays_where_the_array_may_have_shrunk_or_the_index_may_be_out :: proc(t: ^testing.T) {
	result := optimize_text(
		t,
		`
		function popped(values: number[]): number {
			let total = 0;
			for (let i = 0; i < values.length; i++) {
				values.pop();
				total += values[i];
			}
			return total;
		}
		function shrink(values: number[]): number {
			values.pop();
			return 1;
		}
		function called(values: number[], i: number): void {
			values[i] += shrink(values);
		}
		function through(values: number[]): number {
			let total = 0;
			for (let i = 0; i < 10; i++) {
				if (i <= values.length) {
					total += values[i];
				}
			}
			return total;
		}
		function before(values: number[]): number {
			let total = 0;
			for (let i = -1; i < values.length; i++) {
				total += values[i];
			}
			return total;
		}
		const values = [1, 2, 3];
		called(values, 0);
		console.log(popped(values), through(values), before(values));
	`,
	)
	cases := [?]struct {
		name:   string,
		checks: int,
	}{{"m1.popped", 1}, {"m1.called", 2}, {"m1.through", 1}, {"m1.before", 1}}
	for c in cases {
		checks, proved := check_counts(harness.func_named(t, result.output, c.name))
		testing.expectf(t, checks == c.checks && proved == 0, "%s:\n%s", c.name, result.after)
	}
}

// check_counts leaves out the checks lower proved itself, as of the slot a push or a pop takes.
@(private = "file")
check_counts :: proc(body: ir.Func) -> (checks: int, proved: int) {
	_, all := instructions_of(body, ir.Bounds_Check)
	for check in all {
		switch {
		case lower_proved(check):
		case check.proved:
			proved += 1
		case:
			checks += 1
		}
	}
	return
}

// lower_proved tells a check lower proved by its fail sites: it has none, so both are the zero id,
// where any other check has two sites of its own.
@(private = "file")
lower_proved :: proc(check: ir.Bounds_Check) -> bool {
	return check.not_integer == check.out_of_range
}
