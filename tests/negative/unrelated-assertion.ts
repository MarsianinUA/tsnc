// `as` widens a value or narrows a union, so the two types have to be related. Two that are not
// need a conversion, not an assertion. Two unions that merely share a member are not related
// either: neither is a part of the other. An array literal takes the target as its context, and
// one whose elements still do not fit is reported once, at the literal.
// expect: T3020 10:14 "cannot be converted"
// expect: T3020 11:13
// expect: T3020 12:14
// expect: T3020 15:9
const count: number = 1;
const text = count as string;
const bad = "a" as number;
const list = [1] as string[];

function pick(a: "a" | "b"): "b" | "c" {
	return a as "b" | "c";
}
