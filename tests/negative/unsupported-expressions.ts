// Every construct under T2021 that is an expression, in the order the `Construct` enum lists them.
// They share one code, so they share one program; parse rejects each of them on sight. The lines
// after the last one pin where a skipped construct ends: a comma in a `for` header, and a computed
// key whose value runs over two lines, after which the next field is still read.
// expect: T2021 23:16
// expect: T2021 24:18
// expect: T2021 25:19
// expect: T2021 26:17
// expect: T2021 27:14
// expect: T2021 28:17
// expect: T2021 29:18
// expect: T2021 30:18
// expect: T2021 31:22
// expect: T2021 32:23
// expect: T2021 33:16
// expect: T2021 35:15
// expect: T2021 37:19
// expect: T2021 38:20
// expect: T2021 39:20
// expect: T2021 41:2
// expect: T2021 47:11
// expect: T2021 50:2
const pair = (1, 2);
const frozen = 1 as const;
const checked = 1 satisfies number;
const has = "x" in { x: 1 };
const is = 1 instanceof Object;
const nothing = void 0;
const identity = <T>(x: T): T => x;
const asserted = <number>1;
const tagged = String`text`;
const mapped = [1].map<string>((x) => "a");
const loaded = import("./modules/values.ts");
function target(): void {
	const here = new.target;
}
const holes = [1, , 3];
const computed = { ["key"]: 1 };
const numbered = { 1: "one" };
const accessor = {
	get size(): number {
		return 1;
	},
};
let i = 0;
let j = 0;
for (i = 0, j = 1; ; ) {
}
const spanning = {
	["key"]:
		1 + 2,
	c: 1,
};
console.log(spanning.c);
const plain = {
	a:
		1,
};
