// `enum` is not supported in v1: a union of literal types takes its place. A `const enum` too.
// expect: T2013 4:1
// expect: T2013 8:1
enum Color {
	Red,
	Green,
}
const enum Size {
	Small,
}
