// A result inferred from a body that calls the function itself has nothing to settle on. Writing
// the return type after the parameters ends the search.
// expect: T3010 4:10
function loop(n: number) {
	return loop(n);
}
