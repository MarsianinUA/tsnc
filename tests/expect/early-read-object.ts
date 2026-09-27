// A hoisted function reads a `const` object before its declaration ran, which Node answers with a
// ReferenceError: the program prints what came before and fails at the read, exit code 1.
// stdout: before
// stderr: error: cannot access a variable before its initialization at tests/expect/early-read-object.ts:8:9
// exit: 1

function read(): number {
	return box.n;
}

console.log("before");
console.log(read());
const box = { n: 1 };
