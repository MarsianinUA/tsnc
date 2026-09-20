// A function that declares a result has to produce one on every path. The branch that is not taken
// here runs off the end of the body, where a caller would read a value that was never written.
// Adding `| undefined` to the result is the other way out, and then the caller has to test it.
// expect: T3024 5:31
function pick(flag: boolean): number {
	if (flag) {
		return 1;
	}
}
