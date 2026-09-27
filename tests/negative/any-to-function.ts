// A value of type `any` or `unknown` never becomes a function: a call through it would need the
// signature checked at run time, and tsnc checks only the tag. So the flow is refused where it
// happens: a parameter, a field, the result of an inlined arrow, the element an inlined callback
// takes, an `as`, a declarator and a union that holds a function. The first one would call 41
// through a closure of another signature.
// expect: T2029 14:7 "a value of type `any` cannot become a function"
// expect: T2029 17:8 "a value of type `any` cannot become a function"
// expect: T2029 18:15 "a value of type `any` cannot become a function"
// expect: T2029 19:2 "a value of type `any` cannot become a function"
// expect: T2029 22:12 "a value of type `any` cannot become a function"
// expect: T2029 23:6 "a value of type `any` cannot become a function"
// expect: T2029 24:12 "a value of type `unknown` cannot become a function"
type NF = (n: number) => number;
const k: (x: any) => number = (x: NF): number => x(41);
function flows(a: any, anys: any[]): void {
	const loose: { f: any } = { f: a };
	const tight: { f: NF } = loose;
	const made = [1, 2].map((x: number): NF => a);
	anys.forEach((g: NF) => g(1));
}
function asserts(a: any, u: unknown): void {
	const g = a as NF;
	let h: NF | undefined = a;
	const m = u as NF;
}
