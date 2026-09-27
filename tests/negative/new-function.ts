// `new Function` is never supported: requirements 2.2, "Never". Without parentheses as well, and
// inside a function.
// expect: T2008 6:1
// expect: T2008 7:1
// expect: T2008 9:2
new Function("a", "return a");
new Function;
function make(): void {
	new Function("");
}
