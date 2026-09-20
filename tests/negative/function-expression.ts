// Function expressions and object literal methods are not supported: write an arrow function, or
// declare the function by name.
// expect: T2018 5:15
// expect: T2018 9:2
const twice = function (x: number): number {
	return x * 2;
};
const shape = {
	size(): number {
		return 1;
	},
};
