// check keeps what a test narrowed across a call that writes the variable (requirements 3.8), so
// the read after the call finds null where its type says a box. It tests the pointer and fails,
// where Node throws a TypeError reading a field of null.
// stdout: 1
// stderr: error: a value holds a kind its type does not allow at tests/expect/nullable-changed.ts:25:14
// exit: 1

interface Box {
	n: number;
}

function make(): Box | null {
	return { n: 1 };
}

let current: Box | null = make();

function clear(): void {
	current = null;
}

if (current !== null) {
	console.log(current.n);
	clear();
	console.log(current.n);
}
