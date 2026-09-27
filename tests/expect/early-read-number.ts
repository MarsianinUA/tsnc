// A number read before its declaration ran: its binding keeps a ready flag beside it, and the read
// fails where Node throws its ReferenceError.
// stderr: error: cannot access a variable before its initialization at tests/expect/early-read-number.ts:7:9
// exit: 1

function next(): number {
	return count + 1;
}

console.log(next());
let count = 1;
