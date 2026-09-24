// null, undefined and the optional (requirements 2.2, 3.4, 3.8): a comparison with null or
// undefined is a test of the tag, a nullable reference is truthy exactly when it is neither, `??`
// and `||` keep their left side where the test says so, and `x!` checks before it reads. A missing
// optional field or parameter holds undefined. No field is set to undefined explicitly: the console
// cannot tell that from a missing one (requirements 3.9).

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

console.log(first([5]), first([], 7), label(), label("b"), cut("hello", 2), cut("hello"));

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
