// A function value read before its declaration ran is a null closure until then, and the read
// fails where Node throws its ReferenceError.
// stderr: error: cannot access a variable before its initialization at tests/expect/early-read-function.ts:7:9
// exit: 1

function call(): number {
	return later();
}

console.log(call());
const later = (): number => 1;
