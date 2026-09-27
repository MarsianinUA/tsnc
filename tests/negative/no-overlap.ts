// A comparison of two types with no value in common never holds, so it is a mistake rather than a
// test. The same question is what narrows a union member by member, and what a `case` of a
// `switch` asks of its value.
// expect: T3022 8:14
// expect: T3022 9:17 "no value in common"
// expect: T3022 13:8
const count: number = 1;
const same = count === "one";
const literal = 1 === "a";

function pick(v: string): number {
	switch (v) {
		case 1:
			return 0;
	}
	return 1;
}
