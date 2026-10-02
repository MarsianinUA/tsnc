// Two functions that call each other need the result written out on one of them: the other's is
// inferred from a body that calls a signature already settled, from whichever end check starts.

function isEven(n: number) {
	return n === 0 ? true : isOdd(n - 1);
}

function isOdd(n: number): boolean {
	return n === 0 ? false : isEven(n - 1);
}

const half = (n: number): number => (n < 2 ? 0 : 1 + half(n - 2));

console.log(isEven(10), isOdd(7), isEven(3), half(9));
