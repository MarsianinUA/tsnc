// A value of type `any` stays a tagged value: tsnc reads its tag at run time, but converts it to
// nothing and looks nothing up in it. Narrow it first, with `typeof` or `as`. That rules out
// arithmetic on either side, a compound assignment, the unary operators, an order, `++`, a field,
// an index, an index into an array, a call and `for...of`.
// expect: T2029 20:13
// expect: T2029 23:13
// expect: T2029 26:13 "a value of type `any` cannot be an operand of `*`"
// expect: T2029 29:7
// expect: T2029 35:14
// expect: T2029 36:15
// expect: T2029 37:15
// expect: T2029 38:15
// expect: T2029 40:1
// expect: T2029 41:15
// expect: T2029 42:14
// expect: T2029 43:18
// expect: T2029 44:16
// expect: T2029 45:17
const input: any = 21;
console.log(input * 2);

function add(a: any, n: number): number {
	return n + a;
}
function times(a: any, n: number): number {
	return n * a;
}
function less(a: any, n: number): number {
	n -= a;
	return n;
}

const a: any = 1;
let n = 0;
const neg = -a;
const plus = +a;
const flip = ~a;
const lower = a < n;
let b: any = 1;
b++;
const field = a.x;
const item = a[0];
const pick = [1][a];
const called = a();
for (const x of a) {
}
