// forEach inlines its callback as well, here inside a function: the callback reads a local
// declared below it and fails where Node throws its ReferenceError.
// stdout: start
// stderr: error: cannot access a variable before its initialization at tests/expect/early-read-for-each.ts:9:48
// exit: 1

function outer(): number {
	console.log("start");
	[1, 2].forEach((x: number) => console.log(x + step));
	const step = 3;
	return step;
}

console.log(outer());
