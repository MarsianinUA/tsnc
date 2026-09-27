// A `let` of one case used in a later case: a jump to case 1 skips the declaration, and the
// assignment there fails, where Node throws its ReferenceError.
// stdout: 2
// stderr: error: cannot access a variable before its initialization at tests/expect/early-read-switch.ts:12:4
// exit: 1

function pick(n: number): number {
	switch (n) {
		case 0:
			let y = 1;
		case 1:
			y = 2;
			return y;
	}
	return 0;
}

console.log(pick(0));
console.log(pick(1));
