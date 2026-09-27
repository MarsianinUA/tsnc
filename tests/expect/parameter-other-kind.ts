// Once `print` has held `show`, the functions it holds share one signature class, whose parameter
// travels tagged, and `square` unboxes its own with a check on the way in. A string that came
// through `any` fails that check at the parameter, where Node prints NaN.
// stdout: 2
// stdout: 9
// stderr: error: a function was given or returned a value its declared type does not allow at tests/expect/parameter-other-kind.ts:13:16
// exit: 1

function show(value: number | string): void {
	console.log(value);
}

const square = (value: number): void => console.log(value * value);
let print: (value: number) => void = show;
print(2);
print = square;
print(3);
const loose: any = "two";
print(loose);
