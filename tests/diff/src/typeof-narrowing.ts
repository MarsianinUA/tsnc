// `typeof` over a union of primitives (requirements 2.2, 3.4): compared with a word it is a test of
// the tag, and inside the test the value is the member the word names, unboxed after a check. On
// its own, `typeof` of a union asks the runtime for the word; String(x), a template and `===` of a
// union read the tag at run time too. The comparisons take their operands through parameters, since
// tsc refuses `===` between two literal types that cannot meet.

type Value = number | string | boolean | undefined;

function kind(v: Value): string {
  if (typeof v === "number") {
    return "number " + (v + 1);
  } else if (typeof v === "string") {
    return "string " + v.length + " " + v.toUpperCase();
  } else if (typeof v === "boolean") {
    return v ? "yes" : "no";
  }
  return "nothing";
}

function viaSwitch(v: Value): string {
  switch (typeof v) {
    case "number":
      return "n" + v.toFixed(1);
    case "string":
      return "s" + v.slice(0, 1);
    case "boolean":
      return "b" + String(!v);
    default:
      return "u";
  }
}

function notString(v: Value): boolean {
  return typeof v !== "string";
}

function same(a: Value, b: Value): boolean {
  return a === b;
}

function differ(a: Value, b: number): boolean {
  return a !== b;
}

function double(v: number | string): number | string {
  if (typeof v === "number") {
    v *= 2;
  } else {
    v += v;
  }
  return v;
}

const values: Value[] = [1, "ab", true, undefined, false, 2.5, "", 0];
for (const v of values) {
  console.log(kind(v), viaSwitch(v), typeof v, notString(v));
  console.log(String(v), `[${v}]`, "+" + v);
}
console.log(same(1, 1), same(1, "1"), same(undefined, undefined), same("a", "a"));
console.log(same(true, false), same(0, false), same(NaN, NaN), same("", undefined));
console.log(differ(2, 2), differ("2", 2), differ(undefined, 0));
console.log(double(21), double("ab"));
console.log(values.map((v) => typeof v).join(" "));
