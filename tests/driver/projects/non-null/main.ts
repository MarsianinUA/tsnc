// `x!` on a value that turns out undefined: the program prints what it wrote before the check, then
// fails at the start of `x!` with exit code 1 (requirements 3.8).

function first(values: number[], fallback?: number): number {
	return values.length > 0 ? values[0] : fallback!;
}

console.log(first([4]));
console.log(first([]));
