// A function that declares a result has to produce one on every path. The branch that is not taken
// here runs off the end of the body, where a caller would read a value that was never written.
// Adding `| undefined` to the result is the other way out, and then the caller has to test it. An
// arrow is held to the same rule, and so is a `switch` that leaves a case out.
// expect: T3024 8:31
// expect: T3024 14:30
// expect: T3024 20:36
function pick(flag: boolean): number {
	if (flag) {
		return 1;
	}
}

const choose = (c: boolean): number => {
	if (c) {
		return 1;
	}
};

function name(k: "a" | "b" | "c"): number {
	switch (k) {
		case "a":
			return 1;
		case "b":
			return 2;
	}
}
