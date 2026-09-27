// `as` widens a value or narrows a union, so the two types have to be related. Two that are not
// need a conversion, not an assertion. Two unions that merely share a member are not related
// either: neither is a part of the other.
// expect: T3020 8:14 "cannot be converted"
// expect: T3020 9:13
// expect: T3020 12:9
const count: number = 1;
const text = count as string;
const bad = "a" as number;

function pick(a: "a" | "b"): "b" | "c" {
	return a as "b" | "c";
}
