// Arithmetic and bitwise operators take numbers. `+` is the one that also joins text, and it has
// a rule of its own. `++`, `--` and a compound assignment follow the operator they stand for. A
// mistake inside a function is reported once, however often the function is called or read
// before its declaration, and inside an array literal it is still found.
// expect: T3003 11:17
// expect: T3003 14:1
// expect: T3003 16:10
// expect: T3003 21:9
// expect: T3003 26:10
// expect: T3003 31:21
const doubled = "two" * 2;

let word = "a";
word++;
let total = 0;
total *= "a";

const first = broken();
const second = broken();
function broken() {
	return "a" * 2;
}

function outer(): number {
	function inner() {
		return "a" * 2;
	}
	return inner() ? 1 : 2;
}

const numbers = [1, "a" * 2];
