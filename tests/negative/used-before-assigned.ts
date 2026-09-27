// A `let` written with a type and no initializer holds nothing until something assigns to it. Only
// one of the two paths here does, so the read below the branch can find the variable empty. tsnc
// emits no runtime check behind such a read, so the value would be garbage rather than an error.
// A compound assignment reads before it writes, and a function or an arrow made before the first
// write may run before it. An exported `let` is reported at its declaration, since an importer
// cannot know when it is assigned; the importer itself says nothing.
// expect: T3025 21:9
// expect: T3025 26:9
// expect: T3025 31:2
// expect: T3025 33:2
// expect: T3025 38:10
// expect: T3025 43:28
// expect: T3025 modules/unassigned.ts:4:12
import { config } from "./modules/unassigned.ts";

function size(flag: boolean): number {
	let text: string;
	if (flag) {
		text = "a";
	}
	return text.length;
}

function measure(): number {
	let s: string;
	return s.length;
}

function run(): void {
	let s: string;
	s += "a";
	let n: number;
	n++;
}

let total: number;
function add(n: number): void {
	total = total + n;
}
total = 0;

let timer: number;
const step = (): number => timer + 1;
timer = 0;

const configured: number = config;
