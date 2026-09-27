// A result inferred from a body that calls the function itself has nothing to settle on. Writing
// the return type after the parameters ends the search. Two functions that call each other, an
// arrow that calls itself through its variable and two modules whose functions call each other
// are the same loop. Each loop is reported once, at the member declared first: `middle` enters the
// loop over three modules at ringB, yet ringA is reported, and a reader outside it hears nothing.
// expect: T3010 16:10
// expect: T3010 20:10
// expect: T3010 27:7
// expect: T3010 29:17
// expect: T3010 modules/recursive-ring-a.ts:4:17
import { there } from "./modules/recursive-ring.ts";
import { ringA } from "./modules/recursive-ring-a.ts";
import { ringB } from "./modules/recursive-ring-b.ts";
import { count } from "./modules/recursive-ring-user.ts";

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

export function middle() {
	return ringB();
}

export function later() {
	return ringA();
}
