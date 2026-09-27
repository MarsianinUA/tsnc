// An index that is not an integer is a runtime error (requirements 3.8), where Node reads the
// property named "0.5" and answers undefined.
// stdout: 1
// stderr: error: index is not an integer at tests/expect/array-index-fraction.ts:8:9
// exit: 1

function at(values: number[], index: number): number {
	return values[index];
}

console.log(at([1, 2], 0));
console.log(at([1, 2], 0.5));
