// A loop that tests the length once a pass and shortens the array in its body still fails a read
// past the new end, where Node answers undefined: the pop between the test and the read keeps the
// bounds check opt would otherwise remove.
// stdout: 1
// stdout: 2
// stdout: 3
// stderr: error: index out of range at tests/expect/array-shrink.ts:15:15
// exit: 1

function walk(values: number[]): void {
	for (let i = 0; i < values.length; i++) {
		if (i === 3) {
			values.pop();
		}
		console.log(values[i]);
	}
}

walk([1, 2, 3, 4]);
