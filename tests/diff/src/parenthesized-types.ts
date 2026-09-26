// An arrow whose result type is a function type in parentheses: the parser tells the result's
// parentheses from a parameter list by what follows the `(`, as tsc does.

const adder = (k: number): ((a: number) => number) => (a: number) => a + k;
console.log(adder(1)(2));

const pick = (flag: boolean): ((a: number, b: number) => number) | undefined =>
	flag ? (a: number, b: number) => a * b : undefined;
const times = pick(true);
console.log(times === undefined ? "none" : times(6, 7), pick(false));

const handlers: ((n: number) => string)[] = [(n: number) => `#${n}`];
console.log(handlers.map((h: (n: number) => string) => h(3)));
