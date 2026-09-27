// `return` belongs to a function: the top level of a module runs on its way in and has nothing to
// return to, inside a block or not. It completes the family of jumps that jump-outside-loop.ts
// pins. The returned value is still read like any other, so the name it reads resolves.
// expect: T1015 7:1
// expect: T1015 9:2
// expect: T1015 12:1
return 1;
if (true) {
	return 1;
}
const x: number = 1;
return x;
function f(): number {
	return 1;
}
const g = (): number => {
	return 1;
};
