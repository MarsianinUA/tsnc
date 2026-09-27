// A number that a closure made before its declaration shares lives in a box beside a ready flag,
// and the read through the closure fails where Node throws its ReferenceError.
// stderr: error: cannot access a variable before its initialization at tests/expect/early-read-captured-number.ts:7:30
// exit: 1

function outer(): number {
	const twice = (): number => count * 2;
	const early = twice();
	const count = 2;
	return early;
}

console.log(outer());
