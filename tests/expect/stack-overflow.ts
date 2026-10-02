// A recursion with no end overflows the stack. The program fails with exit code 1 and no position,
// where Node throws a RangeError with the same words.
// stdout: before
// stderr: error: Maximum call stack size exceeded
// exit: 1

function depth(n: number): number {
	// The addition after the call keeps -o:speed from turning the recursion into a loop.
	return depth(n + 1) + 1;
}

console.log("before");
console.log(depth(0));
