// A function value read before its declaration ran is a null closure until then.

function call(): number {
	return later();
}

console.log(call());
const later = (): number => 1;
