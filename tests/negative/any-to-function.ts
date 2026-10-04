// A value of type `any` or `unknown` never becomes a function: a call through it would need the
// signature checked at run time, and tsnc checks only the tag. So check refuses the flow where it
// happens: a parameter, a field, the result of an arrow, the parameter of a callback, a declarator,
// a union that holds a function, and an `as` of the value or of an object or array holding it. The
// first one would call 41 through a closure of another signature.
// expect: T2029 18:31 "a value of type `any` cannot become a function"
// expect: T2029 21:27 "a value of type `any` cannot become a function"
// expect: T2029 22:45 "a value of type `any` cannot become a function"
// expect: T2029 23:15 "a value of type `any` cannot become a function"
// expect: T2029 26:12 "a value of type `any` cannot become a function"
// expect: T2029 27:26 "a value of type `any` cannot become a function"
// expect: T2029 28:12 "a value of type `unknown` cannot become a function"
// expect: T2029 29:12 "a value of type `any` cannot become a function"
// expect: T2029 30:12 "a value of type `any` cannot become a function"
// expect: T2029 31:12 "a value of type `any` cannot become a function"
// expect: T2029 32:12 "a value of type `any` cannot become a function"
type NF = (n: number) => number;
const k: (x: any) => number = (x: NF): number => x(41);
function flows(a: any, anys: any[]): void {
	const loose: { f: any } = { f: a };
	const tight: { f: NF } = loose;
	const made = [1, 2].map((x: number): NF => a);
	anys.forEach((g: NF) => g(1));
}
function asserts(a: any, u: unknown, loose: { f: any }, anys: any[]): void {
	const g = a as NF;
	let h: NF | undefined = a;
	const m = u as NF;
	const n = { f: a } as { f: NF };
	const p = [a] as NF[];
	const q = loose as { f: NF };
	const r = anys as NF[];
}
