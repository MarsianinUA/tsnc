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

const text: any = "tagged";
console.log((text as string).toUpperCase(), (text as string).length);

const nothing: any = null;
console.log(nothing ?? "fallback", nothing === null, nothing);

const mixed: unknown = 3;
console.log(mixed, typeof mixed, mixed === 3);
