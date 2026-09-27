// One name holds at most one value and one type in a scope. Two declarations of it do not merge,
// and neither do two interfaces of one name. A parameter, a type parameter, an import and a `let`
// of a `switch` case each declare a name of their scope. A name of another scope, or of the other
// meaning, is free. An exported declaration that repeats a name is one mistake, not an export
// twice as well: an importer gets the first declaration, and a function that repeats a `let`
// exports nothing.
// expect: T4009 20:20
// expect: T4001 21:7
// expect: T4001 24:7
// expect: T4001 27:10
// expect: T4001 29:27
// expect: T4001 32:6
// expect: T4001 38:11
// expect: T2023 42:15
// expect: T4001 42:18
// expect: T4001 52:8
// expect: T4001 modules/redeclared-exports.ts:8:17
// expect: T4001 modules/redeclared-exports.ts:13:17
import { answer } from "./modules/values.ts";
import { exported, lost } from "./modules/redeclared-exports.ts";
const answer: number = 1;

const total: number = 1;
const total: number = 2;

let later = 1;
function later(): void {}

function twice(a: number, a: number): void {}

function shadow(a: number): void {
	let a = 1;
}

interface Pair {
	x: number;
}
interface Pair {
	y: number;
}

function same<T, T>(x: T): T {
	return x;
}

function cases(n: number): void {
	switch (n) {
		case 1:
			let a = 1;
			break;
		case 2:
			let a = 2;
	}
}

const first: number = exported();

let outer = 1;
{
	let outer = 2;
}
for (let i = 0; i < 3; i++) {
	let i = 9;
}
type Size = number;
const Size = 1;
function nested(x: number): void {
	{
		let x = 1;
	}
}
