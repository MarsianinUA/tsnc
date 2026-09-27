// `+` adds two numbers or joins a string with anything. Two booleans are neither, and tsnc does
// not convert them the way JavaScript does. An arrow that takes its parameter from an optional one
// may be handed `undefined`, which is neither either.
// expect: T3004 6:13
// expect: T3004 11:25
const sum = true + false;

function run(cb: (x?: number) => number): number {
	return cb();
}
const answer = run(x => x + 1);
