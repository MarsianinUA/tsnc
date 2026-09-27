// An index past the end of a string is a runtime error (requirements 3.8), where Node answers
// undefined.
// stdout: b
// stderr: error: index out of range at tests/expect/string-index.ts:8:9
// exit: 1

function at(text: string, index: number): string {
	return text[index];
}

console.log(at("ab", 1));
console.log(at("ab", 2));
