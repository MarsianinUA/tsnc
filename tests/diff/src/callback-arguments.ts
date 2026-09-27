// A callback gets every argument Node passes it, even through a type that names fewer: `one`
// holds `two`, which takes an optional second number, so map hands it the index and sort the
// second element.

const two = (a: number, b?: number): number => (b === undefined ? a : a * 100 + b);
const one: (a: number) => number = two;
console.log([5, 6, 7].map(one));

const difference = (a: number, b?: number): number => (b === undefined ? 0 : a - b);
const loose: (a: number) => number = difference;
console.log([3, 1, 2].sort(loose));

const label = (word: string, at?: number): string => `${at}:${word}`;
const plain: (word: string) => string = label;
console.log(["a", "b"].map(plain), plain("c"));

// `narrow` flows into a type that also takes a string label, and map, calling it through `f`, still
// gives it the element alone rather than the index where the label would be.
function run(f: (x: number) => number): number[] {
  return [1, 2].map(f);
}
const narrow = (x: number): number => x * 2;
const joined: (x: number, label: string) => number = narrow;
console.log(run(narrow), joined(1, "a"));
