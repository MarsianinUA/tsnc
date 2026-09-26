// check keeps a narrowing across a call that writes the variable, as tsc does, so after these
// calls it still takes `best`, `count` and `value` for what their initializers made them. The
// program reads what each holds now.

let best: number | undefined = undefined;
[3, 1, 2].forEach((x: number): void => {
	if (best === undefined || x < best) {
		best = x;
	}
});
console.log(best);
console.log(best === undefined ? "none" : "some");

let count: number | undefined = undefined;
function bump(): void {
	count = (count ?? 0) + 1;
}
bump();
bump();
console.log(count ?? 0, count === undefined, count);

let value: number | string = "text";
function change(): void {
	value = 1;
}
change();
console.log(typeof value, typeof value === "number");
switch (typeof value) {
	case "number":
		console.log("a number");
		break;
	default:
		console.log("something else");
}
