// A function has no string form in a compiled program: Node would give its source text, which the
// program does not keep. Print the function itself, which shows `[Function: twice]`, or write its
// name as a string. Every way to ask for the string is refused: a template, `String()`, `+` on
// either side and `+=`. A `let` that holds the function cannot take a string either.
// expect: T2028 16:27
// expect: T2028 18:14
// expect: T2028 19:18
// expect: T2028 20:17
// expect: T2028 21:11
// expect: T2028 23:6
// expect: T2028 25:1
// expect: T3001 25:6
function twice(n: number): number {
	return n * 2;
}
console.log("twice is " + twice);

const a = `${twice}`;
const b = String(twice);
const c = "x" + twice;
const d = twice + "x";
let e = "x";
e += twice;
let g = twice;
g += "x";
