// %s of a function prints its source text in Node, which a compiled program does not keep.
// stderr: error: tsnc cannot convert a function, or an object with its own toString or valueOf, to a string
// exit: 1

function shout(): string {
	return "!";
}
console.log("%s", shout);
