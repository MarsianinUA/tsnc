// A `function` declaration binds its name once, and the name is not a variable. A binding that has
// to hold another function later is written `let name = (...) => ...`.
// expect: T3026 7:1
function one(): number {
	return 1;
}
one = (): number => 2;
