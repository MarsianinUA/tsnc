// Console output (requirements 3.9): several arguments separated by one space and ended by one
// newline, each primitive in the words Node uses, and console.error landing on the other stream.
//
// The last section pins the order as well: the whole list of arguments is evaluated before anything
// of the line is written, so an argument that prints does it ahead of the line it belongs to.

function echo(text: string): void {
  console.log(text);
}

function noisy(value: number): number {
  console.log("evaluating", value);
  return value;
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

// An argument that prints is heard before the line, not in the middle of it.
console.log("first", noisy(1), noisy(2));

// The same when an argument spans several blocks of the compiled function.
console.log(noisy(3) > 0 ? "yes" : "no", noisy(4));

// The argument prints to stdout, and the line it belongs to goes to stderr whole.
console.error("code", noisy(5));
