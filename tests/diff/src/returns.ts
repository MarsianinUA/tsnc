// What a function gives back (requirements 5). An inferred result widens the literals the body
// returns, and takes `undefined` in where the body can run off its end or returns bare beside a
// value. A written result that holds `undefined`, `void` or `any` may end without a `return`, and a
// body that ends in a call that never returns, in an endless loop or in a loop whose body always
// returns needs none. Every function here is called only on paths that return.

function one() {
	return 1;
}

function two(flag: boolean) {
	if (flag) {
		return 1;
	}
	return "a";
}

function nothing() {
	let counter = 1;
	counter += 1;
}

function bare() {
	return;
}

function maybe(flag: boolean) {
	if (flag) {
		return 1;
	}
}

function always(flag: boolean) {
	if (flag) {
		return 1;
	}
	return 2;
}

function early(flag: boolean) {
	if (flag) {
		return;
	}
	return 1;
}

// A `let` takes the inferred result as its type, so each write below fails to compile unless the
// result is as wide as it should be; the `const` fails unless it is no wider.
let widened = one();
widened = 5;
let either = two(true);
either = "b";
let optional = maybe(true);
optional = undefined;
let partial = early(false);
partial = undefined;
const whole: number = always(false);
console.log(widened, either, two(false), optional, maybe(true), maybe(false), whole);
console.log(partial, early(true), early(false));
console.log(nothing(), bare(), typeof nothing(), typeof maybe(false), typeof two(false));

function nothingIf(c: boolean): void {
	if (c) {
		return;
	}
}

function maybeOne(c: boolean): number | undefined {
	if (c) {
		return 1;
	}
}

function anything(c: boolean): any {
	if (c) {
		return 1;
	}
}

function stop(c: boolean): number {
	if (c) {
		return 1;
	}
	process.exit(81);
}

function spin(c: boolean): number {
	while (true) {
		if (c) {
			return 2;
		}
	}
}

function once(n: number): number {
	do {
		return n;
	} while (n > 0);
}

function twice(n: number): number {
	while (n > 0) {
		return n * 2;
	}
	return 0;
}

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

function empty(): void {}

function relay(): number | void {
	return empty();
}

console.log(nothingIf(true), nothingIf(false), maybeOne(true), maybeOne(false));
console.log(anything(true), anything(false), stop(true), spin(true));
console.log(once(3), twice(4), twice(-1), find(3), relay(), typeof relay());
