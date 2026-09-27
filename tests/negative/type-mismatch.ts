// The general assignability rule: a value goes only where its type fits. Requirements 5.
// The literal type of `"many"` is what the message names, since that is what the value is. The
// rule holds for an array element, an index, an assignment, a call argument, a field and a
// discriminated union, whose tag has to name one of its members; a tag that is a name rather than
// a literal leaves the fields to decide. A write to a field of a union has to fit every member.
// expect: T3001 17:23 "type `"many"` is not assignable to type `number`"
// expect: T3001 19:31
// expect: T3001 21:22
// expect: T3001 23:36
// expect: T3001 26:9
// expect: T3001 31:22
// expect: T3001 34:25
// expect: T3001 40:29
// expect: T3001 50:34
// expect: T3001 52:34
// expect: T3001 62:8
const count: number = "many";

const numbers: number[] = [1, "a"];
const digits = [1, 2, 3];
const first = digits["0"];
const pair: number[] = [1, 2];
const mixed: (number | string)[] = pair;

let total = 0;
total = "a";

function twice(n: number): number {
	return n * 2;
}
const answer = twice("a");

const word = "hello";
const part = word.slice("1");

interface Point {
	x: number;
	y: number;
}
const p: Point = { x: 1, y: "two" };

interface Add {
	kind: "add";
	left: number;
}
interface Sub {
	kind: "sub";
	left: number;
}
const times: Add | Sub = { kind: "mul", left: 1 };
const k: "sub" = "sub";
const minus: Add | Sub = { kind: k, left: 1 };

interface A {
	x: number;
}
interface B {
	x: string;
	y: number;
}
function set(u: A | B): void {
	u.x = 1;
}
