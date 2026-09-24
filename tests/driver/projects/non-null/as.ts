// `as` narrows a union by its tag: a string where the program says number fails at the start of the
// `as` expression, with exit code 1 (requirements 3.8).

function asNumber(value: number | string): number {
	return value as number;
}

console.log(asNumber(1));
console.log(asNumber("one"));
