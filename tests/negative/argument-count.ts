// A call passes exactly what the signature takes. A parameter may be left out only where it is
// written `x?: T`, since there is no `arguments` object to read the rest from.
// expect: T3007 7:1
function twice(x: number): number {
	return x * 2;
}
twice(1, 2);
