// map makes an array as long as the one it started on. A callback that shortens the array leaves
// holes at the end of the result in Node, where tsnc has no holes and fails the read past the new
// end.
// stderr: error: index out of range at tests/expect/map-shrink.ts:8:17
// exit: 1

const values = [1, 2, 3];
const doubled = values.map((x: number): number => {
	values.pop();
	return x * 2;
});
console.log(doubled);
