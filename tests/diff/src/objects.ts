// Objects (requirements 3.3 and 3.9): a literal prints its properties in the order Node does, the
// keys that read as array indices first; objects nest, go in and out of functions, and compare by
// identity; an optional field may be left out and set later; a field takes a new value in place.

interface Point {
  x: number;
  y: number;
}

interface Labeled {
  label: string;
  at: Point;
  note?: string;
}

function make(x: number, y: number): Point {
  return { x, y };
}

function shift(p: Point, dx: number): Point {
  return { y: p.y, x: p.x + dx };
}

function describe(item: Labeled): string {
  return item.label + "@" + item.at.x + "," + item.at.y;
}

function same(a: Point, b: Point): boolean {
  return a === b;
}

const origin = make(0, 0);
const moved = shift(origin, 5);
console.log(origin, moved, same(origin, moved), same(origin, origin));

const tag: Labeled = { label: "home", at: moved };
const noted: Labeled = { note: "first", at: origin, label: "start" };
console.log(tag, noted, describe(tag));

// tag.at is moved itself, not a copy of it.
tag.at.y = 7;
console.log(moved, same(tag.at, moved));

tag.note = "set later";
noted.label = "changed";
console.log(tag, noted);

const keys = { b: 1, "10": "ten", a: true, "2": [2], "01": null };
console.log(keys);

const nested = { outer: { inner: { deep: "yes" } }, list: [1, 2] };
nested.outer.inner.deep = "still";
console.log(nested, nested.outer.inner.deep, nested.list.length);

const counter = { n: 0, steps: "" };
for (let i = 0; i < 3; i++) {
  counter.n += i;
  counter.steps += i;
}
counter.n++;
console.log(counter);

const nothing = {};
console.log(nothing, [nothing, { flag: false }]);
