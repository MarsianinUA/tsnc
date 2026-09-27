// A read past the end of an array is a runtime error (requirements 3.8), where Node answers
// undefined.
// stdout: 2
// stderr: error: index out of range at tests/expect/array-index.ts:8:9
// exit: 1

function at(values: number[], index: number): number {
	return values[index];
}

console.log(at([1, 2], 1));
console.log(at([1, 2], 2));
