// Every construct under T2021 that is a declaration, a statement or a module, in the order the
// `Construct` enum lists them. They share one code, so they share one program; parse rejects each
// of them on sight. A string name is refused in an export list as it is in an import list.
// expect: T2021 20:1
// expect: T2021 24:9
// expect: T2021 26:17
// expect: T2021 29:32
// expect: T2021 32:19
// expect: T2021 34:1
// expect: T2021 35:8
// expect: T2021 37:1 "`debugger` statements"
// expect: T2021 39:1
// expect: T2021 41:8
// expect: T2021 42:46
// expect: T2021 43:8
// expect: T2021 44:8
// expect: T2021 45:8
// expect: T2021 46:10
// expect: T2021 47:20
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
export { answer as "text" };
