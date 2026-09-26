// A local that a closure made before its declaration shares lives in a box, which is empty until
// the declaration runs.

function outer(): number {
	const size = (): number => items.length;
	const early = size();
	const items = [1, 2];
	return early;
}

console.log(outer());
