// Every construct under T2021 that is a declaration, a statement or a module, in the order the
// `Construct` enum lists them. They share one code, so they share one program; parse rejects each
// of them on sight, and tests/parse pins the wording of each on its own.
// expect: T2021 19:1
// expect: T2021 23:9
// expect: T2021 25:17
// expect: T2021 28:32
// expect: T2021 31:19
// expect: T2021 33:1
// expect: T2021 34:8
// expect: T2021 36:1
// expect: T2021 38:1
// expect: T2021 40:8
// expect: T2021 41:46
// expect: T2021 42:8
// expect: T2021 43:8
// expect: T2021 44:8
// expect: T2021 45:10
function overloaded(x: number): number;
function overloaded(x: number): number {
	return x;
}
function* counter() {
}
interface Sized extends Point {
	size: number;
}
function withDefault(x: number = 1): number {
	return x;
}
function withThis(this: number): void {
}
outer: while (true) {
	break outer;
}
debugger;
let item: number = 0;
for (item of [1, 2]) {
}
import legacy = require("./modules/values.ts");
import { answer } from "./modules/values.ts" with { type: "json" };
export * from "./modules/values.ts";
export = answer;
export import alias = legacy.answer;
import { "answer" as renamed } from "./modules/values.ts";
