// Every construct under T2021 that is an expression, in the order the `Construct` enum lists them.
// They share one code, so they share one program; parse rejects each of them on sight, and
// tests/parse pins the wording of each on its own.
// expect: T2021 20:16
// expect: T2021 21:18
// expect: T2021 22:19
// expect: T2021 23:17
// expect: T2021 24:14
// expect: T2021 25:17
// expect: T2021 26:18
// expect: T2021 27:18
// expect: T2021 28:22
// expect: T2021 29:23
// expect: T2021 30:16
// expect: T2021 32:15
// expect: T2021 34:19
// expect: T2021 35:20
// expect: T2021 36:20
// expect: T2021 38:2
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
