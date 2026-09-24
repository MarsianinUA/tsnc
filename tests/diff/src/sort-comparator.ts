// sort with a comparator: the runtime calls the closure back with two elements as the array holds
// them. The sort is stable, undefined goes last without a call, and the array is sorted in place.
// No comparator here prints or counts: the runtime calls it in another order than V8 does.

interface Item {
  name: string;
  price: number;
}

const numbers = [5, 1, 4, 2, 3, 10, -1];
console.log(numbers.sort((a, b) => a - b));
console.log(numbers.sort((a, b) => b - a), numbers);

const words = ["pear", "fig", "banana", "kiwi", "apple", "plum"];
console.log(words.sort((a, b) => a.length - b.length));

const items: Item[] = [
  { name: "tea", price: 3 },
  { name: "cake", price: 5 },
  { name: "bun", price: 2 },
  { name: "jam", price: 3 },
];
console.log(items.sort((a, b) => a.price - b.price));
console.log(items.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)));

const flags = [true, false, true, false];
console.log(flags.sort((a, b) => (a ? 1 : 0) - (b ? 1 : 0)));

const holes: (number | undefined)[] = [3, undefined, 1, undefined, 2];
console.log(holes.sort((a, b) => 0));

function descending(a: number, b: number): number {
  return b - a;
}
console.log([7, 9, 8].sort(descending));

let pivot = 5;
const byDistance = (a: number, b: number): number => Math.abs(a - pivot) - Math.abs(b - pivot);
console.log([1, 9, 4, 6, 5].sort(byDistance));
pivot = 0;
console.log([1, -9, 4, -2].sort(byDistance));

const many: number[] = [];
for (let i = 0; i < 100; i++) {
  many.push((i * 37) % 101);
}
const sorted = many.sort((a, b) => a - b);
console.log(sorted.length, sorted[0], sorted[50], sorted[99], sorted === many);
