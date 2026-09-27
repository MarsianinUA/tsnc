// `==` is allowed only where it already means `===`: both sides of one type, and a type that holds
// one kind of value. Two sides of `number | string` could still be converted into each other, and
// so could `any`, `null | undefined` and `number | boolean`. Requirements 3.7.
// expect: T3002 12:14 "use `===`"
// expect: T3002 13:17
// expect: T3002 15:9
// expect: T3002 18:12
// expect: T3002 19:12
// expect: T3002 22:9
// expect: T3002 22:19
const text: string = "1";
const same = 1 == text;
const literal = 1 == "a";
function equal(a: number | string, b: number | string): boolean {
	return a == b;
}
function kinds(a: any, b: any, n: null | undefined, m: null | undefined): void {
	const x = a == b;
	const y = n != m;
}
function mixed(p: number | string, q: number | string, r: number | boolean): boolean {
	return p == q || r == r;
}
