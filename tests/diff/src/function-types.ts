// A function accepted where another function type is expected is the same function after the flow,
// so `===` holds and nothing is copied. Where the two types disagree on how an argument or the
// result is held, the program gives both one signature, boxing the difference, and each function
// unboxes what it declared on the way in. A value the function's own type does not allow could only
// come through `any`, which this corpus does not do.

function show(x: number | string): void {
  console.log("show", x);
}

const square = (x: number): void => console.log("square", x * x);
let printer: (x: number) => void = square;
printer(3);
printer = show;
printer(4);
show("text");
console.log(printer === show);

// A function that answers a number, called through a type that throws the answer away: Node still
// hands the number back.
const five = (): number => 5;
const ignore: () => void = five;
ignore();
console.log(ignore(), five(), ignore === five);

// Fewer parameters than the callback type offers.
function twice(f: (x: number) => number, v: number): number {
  return f(f(v));
}
const one = (): number => 1;
console.log(twice(one, 3), twice((x) => x * 2, 3));

function describe(a: number, b?: number): void {
  console.log("describe", a, b);
}
const unary: (a: number) => void = describe;
unary(1);
describe(2, 3);

const handlers: ((n: number) => void)[] = [];
handlers.push(square);
handlers.push(show);
handlers.push((n: number) => console.log("arrow", n));
handlers.forEach((h) => h(7));
for (const handler of handlers) {
  handler(8);
}
console.log(handlers);

// push is the one flow between these two types.
const shouts: ((s: string) => void)[] = [];
const shout = (s: string | boolean): void => console.log("shout", s);
shouts.push(shout);
shouts[0]("hey");

// A comparator whose class holds an argument otherwise than the array holds its elements goes to
// the runtime through an adapter: here the first one tagged, or a third one it never takes.
const second = (a: number | string, b: number): number => b;
const pick: (a: number, b: number) => number = second;
const ascending = (a: number, b: number): number => a - b;
console.log([3, 1, 2, 10].sort(ascending), pick(1, 2));
const byLength = (a: string, b: string): number => a.length - b.length;
const loose: (a: string, b: string, c?: number) => number = byLength;
console.log(["ccc", "a", "bb"].sort(byLength), loose("xx", "y"));

interface Button {
  label: string;
  onClick: (times: number) => void;
}

const button: Button = { label: "ok", onClick: show };
button.onClick(2);
const other: Button = { label: "no", onClick: (t: number) => console.log("clicked", t) };
other.onClick(3);
console.log(button, other.onClick === button.onClick);
