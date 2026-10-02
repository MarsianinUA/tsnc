// size has its result written out, so its body is read after the type of total is settled and
// closes no loop, as in tsc. The call reads total before its initializer ran, and the read fails
// where Node throws its ReferenceError.
// stderr: error: cannot access a variable before its initialization at tests/expect/early-read-annotated-result.ts:9:9
// exit: 1

let total = size();
function size(): number {
	return total + 1;
}
console.log(total);
