// A result inferred from a body that calls the function itself has nothing to settle on. Writing
// the return type after the parameters ends the search. Two functions that call each other, an
// arrow that calls itself through its variable and two modules whose functions call each other
// are the same loop, and each loop is reported once.
// expect: T3010 11:10
// expect: T3010 15:10
// expect: T3010 22:7
// expect: T3010 24:17
import { there } from "./modules/recursive-ring.ts";

function loop(n: number) {
	return loop(n);
}

function first() {
	return second();
}
function second() {
	return first();
}

const fact = (n: number) => (n <= 1 ? 1 : n * fact(n - 1));

export function here() {
	return there();
}
