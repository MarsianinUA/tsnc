// sort with a comparator: the runtime calls the closure back with two elements as the array holds
// them. The sort is stable, undefined goes last without a call, and the array is sorted in place.
// No comparator here prints or counts, and one that changes the array does it on its first call
// only: the runtime calls it in another order than V8 does.

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
console.log(holes.sort((a, b) => (a ?? -1) - (b ?? -1)));

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

// Equal elements keep their order, and a comparator that answers NaN makes every pair equal. Only
// the sign of an answer counts, so a fraction or an infinity is as good as 1.
console.log([2.5, 1.9, 2.1, 1.1, 2.0].sort((a, b) => Math.floor(a) - Math.floor(b)));
console.log([3, 1, 2].sort(() => NaN));
console.log([0.3, 0.1, 0.25, 0.2].sort((a, b) => (a - b) / 1000));
console.log([3, 1, 2, 5, 4].sort((a, b) => (a < b ? -Infinity : Infinity)));

// Node sorts the elements the array held when the sort began and writes them back from index 0: a
// comparator that pushes leaves its element after them, one that pops makes the array grow back,
// and a sort of the same array inside the comparator is written over.
const pushed = [3, 1, 2];
let pushOnce = true;
pushed.sort((a, b) => {
  if (pushOnce) {
    pushOnce = false;
    pushed.push(9);
  }
  return a - b;
});
const popped = [3, 1, 2];
let popOnce = true;
popped.sort((a, b) => {
  if (popOnce) {
    popOnce = false;
    popped.pop();
    popped.pop();
  }
  return a - b;
});
const resorted = [3, 1, 2];
let sortOnce = true;
resorted.sort((a, b) => {
  if (sortOnce) {
    sortOnce = false;
    resorted.sort((p, q) => q - p);
  }
  return a - b;
});
console.log(pushed, popped, resorted);

// 5,000 numbers with 50 keys, their integer parts. Each fraction records where its number started,
// so a stable sort by key leaves the whole array ascending.
const keyed: number[] = [];
let seed = 1;
for (let i = 0; i < 5000; i++) {
  seed = (seed * 75 + 74) % 65537;
  keyed.push((seed % 50) + i / 5000);
}
keyed.sort((a, b) => Math.floor(a) - Math.floor(b));
let ascending = true;
let checksum = 0;
for (let i = 0; i < keyed.length; i++) {
  if (i > 0 && keyed[i - 1] > keyed[i]) {
    ascending = false;
  }
  checksum = (checksum * 31 + Math.round(keyed[i] * 5000)) % 1000000007;
}
console.log(ascending, checksum, keyed[0], keyed[4999]);
