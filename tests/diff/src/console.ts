// Console output (requirements 3.9): several arguments separated by one space and ended by one
// newline, each primitive in the words Node uses, and console.error landing on the other stream.
//
// No argument here has a side effect of its own. tsnc writes each argument as it evaluates it,
// while Node evaluates the whole list before it writes anything, and a corpus program should pin
// the output rather than that difference.

function echo(text: string): void {
  console.log(text);
}

const nothing = undefined;
const empty = null;

console.log("plain");
console.log(1, "two", true);
console.log(nothing, empty);
console.log("mixed", 1.5, false, empty, nothing);

// No arguments at all is still a line.
console.log();

echo("through a parameter");

// A number keeps its own text inside a list of arguments, negative zero included.
console.log(-0, 0, 1e21, NaN);

console.error("to stderr");
console.error("code", 2, false);
