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

// A union prints as whatever it holds when the line is written.
function maybe(flag: boolean): number | undefined {
  return flag ? 1 : undefined;
}

function either(flag: boolean): string | number {
  return flag ? "text" : 2;
}

function nullable(flag: boolean): boolean | null {
  return flag ? false : null;
}

console.log(maybe(true), maybe(false), either(true), either(false));
console.log(nullable(true), nullable(false), -0 as number | undefined);
console.error(either(false), maybe(false));

// A union that holds a string at run time is a format string there, as in Node.
console.log(either(true), "%s");

// A string with a percent sign is a format string only when more arguments follow it.
console.log("100%");
console.log("100%", "done");
console.log("%s of %d", "one", 2);
console.log("50%% off", nothing);
