// A call passes exactly what the signature takes. A parameter may be left out only where it is
// written `x?: T`, since there is no `arguments` object to read the rest from. The methods of the
// built-in lib count the same way.
// expect: T3007 11:1
// expect: T3007 16:13
// expect: T3007 17:14
// expect: T3007 20:14
function twice(x: number): number {
	return x * 2;
}
twice(1, 2);

function pair(a: number, b: number): number {
	return a + b;
}
const few = pair(1);
const many = twice(1, 2);

const numbers = [1, 2, 3];
const part = numbers.slice(1, 2, 3);
