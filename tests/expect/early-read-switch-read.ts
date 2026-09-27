// A `let` of one case read in a later case: a jump to case 1 skips the declaration, and the read
// there fails where Node throws its ReferenceError. The declared type holds undefined only to keep
// tsc from refusing the read as a use before assignment (TS2454).
// stdout: 1
// stdout: 2
// stderr: error: cannot access a variable before its initialization at tests/expect/early-read-switch-read.ts:14:16
// exit: 1

function pick(n: number): number {
	switch (n) {
		case 0:
			let y: number | undefined = 1;
		case 1:
			console.log(y);
			return 2;
	}
	return 0;
}

console.log(pick(0));
console.log(pick(1));
