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
