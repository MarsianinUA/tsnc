// join (the Array methods of 2.2): each element as String writes it, except undefined and null,
// which add nothing, and "," for a separator it is not given or that is undefined when it runs. An
// inner array joins in place with commas whatever the outer separator is, and an array met again
// inside its own join adds nothing, as in V8.

function separator(use: boolean): string | undefined {
  return use ? " - " : undefined;
}

function id(x: number): number {
  return x;
}

const numbers = [1, 2, 3];
console.log(numbers.join(separator(false)));
console.log(numbers.join(separator(true)));
console.log(numbers.join(undefined));
console.log(numbers.join());
console.log(["a", "b"].join(""));

const empty: number[] = [];
console.log([1, 2.5, id(-0), id(NaN), 1e21].join(), [true, false].join(), empty.join());
console.log(["a", "b"].join("\u{1F600}"), ["a", "b", "c"].join(""), [{ x: 1 }].join());
console.log([1, undefined, null, true, "x"].join("-"));

const none: number[] = [];
const nested = [[1, [2, 3]], none, 4];
console.log(nested.join(), nested.join(" "));

const ring: unknown[] = [1];
ring.push(ring);
ring.push(2);
const b: unknown[] = [1];
const c: unknown[] = [2, b];
b.push(c);
console.log(ring.join(), b.join(), c.join("-"));
