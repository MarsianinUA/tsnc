// `var` is never supported: requirements 2.2, "Never". Every declaration is reported, in a loop
// header and inside a function too, so the parser does not stop at the first one. A `for` keeps
// the rest of its header, which reads the `let` above it.
// expect: T2001 11:1
// expect: T2001 12:1
// expect: T2001 15:6
// expect: T2001 17:6
// expect: T2001 19:1
// expect: T2007 19:12
// expect: T2001 21:2
var count = 1;
var step = 2;
let i = 0;
const items: number[] = [1, 2];
for (var i = 0; i < 3; i++) {
}
for (var item of items) {
}
var both = eval("1");
function g(): void {
	var inner = 1;
}
