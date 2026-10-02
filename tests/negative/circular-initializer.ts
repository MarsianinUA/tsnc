// A variable takes its type from its initializer, and this initializer reads the variable it is
// defining, so there is nothing to take it from. Writing the type after the name ends the search.
// A function whose result is written out is typed without reading its body, so `total` is no loop:
// tsc accepts it, and the read that runs before the initializer has fails when the program runs.
// expect: T3027 7:5

let step = step + 1;

let total = size();
function size(): number {
	return total;
}
