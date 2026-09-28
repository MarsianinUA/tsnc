// null, undefined and the optional (requirements 2.2, 3.4, 3.8): a comparison with null or
// undefined is a test of the tag, or of the pointer where a reference holds 0 for it, a nullable
// reference is truthy exactly when it is neither, `??` and `||` keep their left side where the test
// says so, and `x!` checks before it reads. A missing optional field or parameter holds undefined.
// No field is set to undefined explicitly: the console cannot tell that from a missing one
// (requirements 3.9).

interface Item {
  value: number;
  next: Item | null;
}

function list(n: number): Item | null {
  let head: Item | null = null;
  for (let i = n; i > 0; i--) {
    head = { value: i, next: head };
  }
  return head;
}

function sum(head: Item | null): number {
  let total = 0;
  let at = head;
  while (at !== null) {
    total += at.value;
    at = at.next;
  }
  return total;
}

function values(head: Item | null): string {
  const out: string[] = [];
  for (let at = head; at; at = at.next) {
    out.push(String(at.value));
  }
  return out.join("->");
}

console.log(sum(list(4)), sum(null), values(list(3)), values(null) === "");
console.log(list(2));

interface Options {
  name?: string;
  count?: number;
  verbose?: boolean;
}

function greet(o: Options): string {
  const name = o.name ?? "world";
  const count = o.count || 1;
  const loud = o.verbose === undefined ? "?" : o.verbose ? "!" : ".";
  return name + " x" + count + loud;
}

console.log(greet({}), greet({ name: "a" }), greet({ count: 3, verbose: true }));
console.log(greet({ name: "", count: 0, verbose: false }));
const partial: Options = { count: 2 };
console.log(partial, partial.name === undefined, partial.count !== undefined);

function first(xs: number[], fallback?: number): number {
  return xs.length > 0 ? xs[0] : fallback!;
}

function label(text?: string): string {
  return text === undefined ? "(none)" : text.toUpperCase();
}

function cut(text: string, end?: number): string {
  return text.slice(0, end);
}

console.log(first([5]), first([], 7), label(), label(undefined), label("b"));
console.log(cut("hello", 2), cut("hello"));

type Handler = (x: number) => number;

function apply(h: Handler | null, x: number): number {
  if (h === null) {
    return x;
  }
  return h(x);
}

let handler: Handler | undefined;
console.log(handler === undefined, apply(null, 3));
handler = (x: number) => x * 2;
if (handler) {
  console.log(handler(21), apply(handler, 5));
}

let maybe: number | null = null;
console.log(maybe ?? "none", maybe === null);
maybe = 4;
console.log(maybe ?? "none", maybe + 1);

let seed: number | null = 3;
console.log(seed + 1);

// A reference with one of null and undefined is one pointer, 0 standing for that null or undefined.
interface Box {
  n: number;
}

interface Slots {
  b: Box | null;
  u: Box | undefined;
  s?: string;
}

type Count = () => number;

function show(b: Box | null, u: Box | undefined, s: string | null, f: Count | undefined): void {
  const slots: Slots = { b: b, u: u };
  console.log(b, u, s, slots, typeof b, typeof u, typeof s, typeof f);
  console.log("%j", slots, `${s}`, String(s), "s=" + s);
  console.log(!b, !u, !s, !f, s ?? "-", u ?? "none", f === undefined ? 0 : f());
}

show(null, undefined, null, undefined);
show({ n: 1 }, { n: 2 }, "x", () => 5);

function same(b: Box | null, u: Box | undefined): boolean {
  return b === u;
}

function soften(b: Box | null): Box | undefined {
  return b ?? undefined;
}

function either(b: Box | null): Box | undefined {
  return b || undefined;
}

function tagOf(b: Box | null, s: string): string | null {
  return b && s;
}

function kind(b: Box | null): string {
  switch (b) {
    case null:
      return "empty";
    default:
      return "box";
  }
}

function widen(b: Box | null): Box | number | null {
  return b;
}

const one: Box = { n: 1 };
console.log(same(null, undefined), same(one, one), soften(null), either(null), either(one));
console.log(tagOf(null, "t"), tagOf(one, "t"), kind(null), kind(one), widen(null), widen(one));

const loose: any = null;
const tight: Box | null = loose;
const back: any = tight;
console.log(tight, back === null);

function find(xs: Box[], n: number): Box | undefined {
  for (const x of xs) {
    if (x.n === n) {
      return x;
    }
  }
}

console.log(find([one], 1), find([one], 2));

// The loop variable enters as a present Item and comes back as the Item | null of `next`.
function length(item: Item): number {
  let n = 0;
  let at: Item | null = item;
  while (at !== null) {
    n++;
    at = at.next;
  }
  return n;
}

const chain: (Item | null)[] = [list(1), null, list(2)];
const lastSome = chain.reduce(
  (acc: Item | null, x: Item | null) => (x === null ? acc : x),
  list(3)!
);
console.log(length(list(3)!), lastSome);

const boxes: (Box | null)[] = [one, null];
boxes.push(null);
console.log(boxes, boxes.indexOf(null), boxes.includes(one), boxes.length);
console.log("%j", boxes);

const names: (string | null)[] = ["b", null, "a"];
const later: (string | undefined)[] = ["z", undefined, "a", undefined];
console.log(names.join("+"), names.sort(), later.sort());
const byN = (a: Box | null, b: Box | null): number => (a === null ? -1 : b === null ? 1 : a.n - b.n);
const holes: (Box | null)[] = [{ n: 3 }, null, { n: 1 }];
console.log(holes.sort(byN));

// A narrowing survives the call that stores a box; the value printed is the box.
let current: Box | null = null;
function load(): void {
  current = { n: 7 };
}
load();
console.log(current);

// peek may run before watched is declared, so a flag, not null, tells that it has not.
function peek(): Box | null {
  return watched;
}
let watched: Box | null = { n: 1 };
watched = null;
console.log(peek());
