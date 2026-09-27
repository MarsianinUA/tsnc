// A binding with neither an annotation nor an initializer has no type to infer from. Requirements
// 5: tsnc infers inside a file, it never guesses. A parameter always needs its type, unless it is
// the parameter of an arrow passed where a function type is expected.
// expect: T3008 7:5
// expect: T3008 9:16
// expect: T3008 12:15
let pending;

function halve(n): number {
	return 1;
}
const twice = x => x * 2;
