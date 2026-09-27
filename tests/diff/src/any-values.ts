// `any` and `unknown` (requirements 3.4): a value kept as a tagged value. `typeof` narrows it as
// tsc does, and inside the test it is the type the word names, unboxed after a check of its tag.
// Printing it, comparing it with `===`, testing it for truth and making a string of it read the tag
// at run time. An `any` flows into a static type with a check (requirements 3.8), and `as` converts
// it the same way. Everything else a program might do to an `any` is a compile error, and so is an
// `any` becoming a function, so this program does none of it.

function describe(a: any): string {
  if (typeof a === "number") {
    return "number " + (a * 2);
  }
  if (typeof a === "string") {
    return "string of " + a.length;
  }
  if (typeof a === "boolean") {
    return a ? "true value" : "false value";
  }
  if (typeof a === "undefined") {
    return "undefined value";
  }
  return "something else";
}

function measure(u: unknown): number {
  if (typeof u === "string") {
    return u.length;
  }
  if (typeof u === "number") {
    return u;
  }
  return -1;
}

function same(a: any, b: any): boolean {
  return a === b;
}

const inputs: any[] = [21, "abc", true, undefined, null];
for (const input of inputs) {
  console.log(describe(input), typeof input, String(input), `<${input}>`, !input, "#" + input);
}
console.log(measure("four"), measure(4), measure(true), measure(null));
console.log(same(1, 1), same("a", "a"), same(1, "1"), same(null, undefined), same(null, null));

const implicit: any = 42;
const n: number = implicit;
console.log(n + 1, implicit ?? "missing", implicit === 42);
const absent: any = undefined;
const maybe: number | undefined = implicit;
const empty: number | undefined = absent;
console.log(maybe, empty);

const text: any = "tagged";
console.log((text as string).toUpperCase(), (text as string).length);

const nothing: any = null;
console.log(nothing ?? "fallback", nothing === null, nothing);

const mixed: unknown = 3;
console.log(mixed, typeof mixed, mixed === 3);

// A primitive's word narrows `any` and `unknown` to that type, while "object" leaves `any` as it
// was.
function classify(a: any, u: unknown): number {
  if (typeof a === "number" && typeof u === "string") {
    return a + u.length;
  }
  if (typeof a === "object") {
    return a === null ? 0 : 2;
  }
  if (typeof u === "undefined") {
    return u === undefined ? 3 : 4;
  }
  return 1;
}

console.log(classify(1, "ab"), classify(null, 1), classify("s", undefined), classify(true, 1));

// Every kind a tagged value can hold, through typeof, truthiness and String. A function stays out
// of String: Node prints its source, which tsnc does not keep, so it refuses at run time.
function f(): void {}

function g(): void {}

function sumOf(a: number, b: number): number {
  return a + b;
}

function glue(a: string, b: string): string {
  return a + b;
}

const point = { x: 1 };
const twin = { x: 1 };
const tags: any[] = [undefined, null, false, true, 0, -0, NaN, 1, -1, Infinity, 5e-324, "", "0", " ", point, [1], f];
for (const value of tags) {
  console.log(typeof value, !value);
}
const printable: any[] = [undefined, null, true, false, -0, NaN, Infinity, -Infinity, 1e21, sumOf(0.1, 0.2), 1.5, point];
console.log(printable.map((value) => String(value)));

// === goes by the tag first: a number never equals a string or a boolean, and undefined never
// equals null. Then a number by IEEE 754, a string by its units, and anything else by identity.
const left: any[] = [NaN, -0, 1.5, sumOf(0.1, 0.2), Infinity, true, true, undefined, null, undefined, 0];
const right: any[] = [NaN, 0, 1.5, 0.3, Infinity, true, false, undefined, null, null, false];
left.push(1, 0, glue("a", "b"), "ab", "", "", point, point, f, f);
right.push("1", undefined, "ab", "ac", glue("", ""), "ab", point, twin, f, g);
const answers: boolean[] = [];
for (let i = 0; i < left.length; i++) {
  answers.push(same(left[i], right[i]), same(right[i], left[i]));
}
console.log(answers);
