// A local that a closure made before its declaration shares lives in a box, which is empty until
// the declaration runs: the array read through it fails where Node throws its ReferenceError.
// stderr: error: cannot access a variable before its initialization at tests/expect/early-read-captured.ts:7:29
// exit: 1

function outer(): number {
	const size = (): number => items.length;
	const early = size();
	const items = [1, 2];
	return early;
}

console.log(outer());
