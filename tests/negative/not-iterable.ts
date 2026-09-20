// `for...of` walks an array or a string. Anything else needs a `for` loop with an index, since
// there are no iterators in v1.
// expect: T3023 5:21
const count: number = 1;
for (const digit of count) {
	console.log(digit);
}
