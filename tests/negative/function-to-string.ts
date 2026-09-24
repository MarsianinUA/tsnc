// A function has no string form in a compiled program: Node would give its source text, which the
// program does not keep. Print the function itself, which shows `[Function: twice]`, or write its
// name as a string.
// expect: T2028 8:27
function twice(n: number): number {
	return n * 2;
}
console.log("twice is " + twice);
