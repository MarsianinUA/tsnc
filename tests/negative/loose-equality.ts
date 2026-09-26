// `==` is allowed only where it already means `===`: both sides of one type, and a type that holds
// one kind of value. Two sides of `number | string` could still be converted into each other.
// Requirements 3.7.
// expect: T3002 7:14
// expect: T3002 9:9
const text: string = "1";
const same = 1 == text;
function equal(a: number | string, b: number | string): boolean {
	return a == b;
}
