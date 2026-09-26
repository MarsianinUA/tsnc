// env: FORCE_COLOR= NO_COLOR= NODE_DISABLE_COLORS=
//
// FORCE_COLOR set to the empty string forces 16 colors in Node, as "1" does (requirements 3.9), so
// this output is colored through the runner's pipe. The two other variables are set empty only to
// keep Node from warning that they are ignored.

console.log("text", 1, true, null, undefined, [2, "two"]);
console.log({ name: "tsnc", ready: false });
