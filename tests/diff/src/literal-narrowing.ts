// Literal types through the flow (requirements 2.2, 5): a `const` keeps the literal its initializer
// wrote while a `let` widens to the whole primitive, a minus in front of a number is part of the
// literal, `switch` narrows a union of literals case by case, and `!` and indexing answer one type
// whatever they are given. The annotated bindings pin each type, since a wrong one would not
// compile.

const fixed = 42;
let loose = 42;
const text = "a";
let words = "a";
const flag = true;
let switched = true;

const exactly: 42 = fixed;
const letter: "a" = text;
const yes: true = flag;
loose = 7;
words = "b";
switched = false;
console.log(exactly, letter, yes, loose, words, switched);

// `-0` is the literal type 0, and the value keeps its sign.
const negated = -1;
const minusOne: -1 = negated;
const zero: 0 = -0;
console.log(minusOne, zero, 1 / zero);

function nots(word: string, count: number, list: number[] | null): boolean[] {
	return [!word, !count, !list];
}

function initial(choice: "ab" | "cd"): string {
	const first: string = choice[0];
	return first;
}

console.log(nots("", 0, null), nots("x", 2, []), initial("ab"), initial("cd"));

// The cases that lead to one body narrow to their union, and the path where none matched to what
// they left. The annotations say no wider, and the comparisons with a member say no narrower: one
// with a member the type lacks would not compile.
function pick(v: "a" | "b" | "c"): string {
	switch (v) {
		case "a":
		case "b": {
			const early: "a" | "b" = v;
			return (v === "b" ? "second " : "first ") + early;
		}
	}
	const late: "c" = v;
	return "late " + late;
}

type Kind = "a" | "b" | "c";

function rank(k: Kind): number {
	switch (k) {
		case "a":
			return 1;
		case "b":
			return 2;
		case "c":
			return 3;
		default: {
			const unreachable: never = k;
			return unreachable;
		}
	}
}

function first(k: Kind): string {
	switch (k) {
		case "a":
			return "first";
		default: {
			const rest: "b" | "c" = k;
			return (k === "c" ? "last " : "rest ") + rest;
		}
	}
}

const kinds: Kind[] = ["a", "b", "c"];
console.log(kinds.map(pick), kinds.map(rank), kinds.map(first));
