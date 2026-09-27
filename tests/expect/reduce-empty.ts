// reduce with no initial value has nothing to start from on an empty array: the program fails at
// the call with exit code 1, where Node throws a TypeError with the same words.
// stdout: 3
// stderr: error: Reduce of empty array with no initial value at tests/expect/reduce-empty.ts:8:9
// exit: 1

function total(values: number[]): number {
	return values.reduce((sum, value) => sum + value);
}

console.log(total([1, 2]));
console.log(total([]));
