// `with` is never supported: requirements 2.2, "Never". A `var` in its body is reported as well,
// and so is a `with` inside a function.
// expect: T2002 7:1
// expect: T2002 9:1
// expect: T2001 10:2
// expect: T2002 13:2
with (shape) {
}
with (shape) {
	var y = 1;
}
function g(): void {
	with (shape) {
	}
}
