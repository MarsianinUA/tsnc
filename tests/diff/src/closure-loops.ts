// A `let` in a `for` header is a new binding on every pass (requirements 3.5), so closures made in
// a loop see different values; one made in the header's own initializer keeps the first binding.
// A `const` of a `for...of`, and a `let` inside a loop body, are new on every pass as well. Many
// closures that outlive their loop keep their environments alive through every collection.

const counters: (() => number)[] = [];
for (let i = 0; i < 3; i++) {
  counters.push(() => i);
}
console.log(counters.map((f) => f()));

// The body changes the binding of its own pass, and the next pass starts from that value.
const steps: (() => number)[] = [];
for (let i = 0; i < 10; i++) {
  i += 2;
  steps.push(() => i * 10);
}
console.log(steps.map((f) => f()));

// A closure made by the initializer reads the first binding, which the body never touches.
const seen: number[] = [];
for (let i = 0, get = () => i; i < 3; i++) {
  i += 10;
  seen.push(get());
}
console.log(seen);

const letters: (() => string)[] = [];
for (const letter of ["a", "b", "c"]) {
  letters.push(() => letter + letter);
}
console.log(letters.map((f) => f()));

const tenths: (() => number)[] = [];
let n = 0;
while (n < 4) {
  const tenth = n / 10;
  let bump = 0;
  tenths.push(() => tenth + bump);
  bump = 1;
  n++;
}
console.log(tenths.map((f) => f()));

// A closure made inside an inlined callback captures the callback's parameter.
const scaled = [1, 2, 3].map((x) => (k: number) => x * k);
console.log(scaled.map((f) => f(10)));

const labels = ["x", "y"].map((name, index) => () => name + index);
console.log(labels.map((f) => f()));

// Hundreds of closures, each with its own environment, stay reachable only through the array.
const kept: (() => number)[] = [];
for (let i = 0; i < 300; i++) {
  let square = i * i;
  kept.push(() => square + i);
  square += 1;
}
let total = 0;
for (const f of kept) {
  total += f();
}
console.log(kept.length, total, kept[7](), kept[299]());

// A `continue` still ends the pass, and the next one gets its own binding.
const odds: (() => number)[] = [];
for (let i = 0; i < 6; i++) {
  if (i % 2 === 0) {
    continue;
  }
  odds.push(() => i);
}
console.log(odds.map((f) => f()));
