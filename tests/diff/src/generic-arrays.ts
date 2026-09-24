// `Array<T>` (requirements 2.2) is the same type as `T[]`, nested or mixed with it. `map<U>` infers
// U from the callback, so the result may hold another element type, and `reduce<U>` may carry an
// initial value of another type than the elements. Type arguments are never written: v1 infers
// them all.

interface Entry {
  key: string;
  counts: Array<number>;
}

function total(values: Array<number>): number {
  return values.reduce((sum, value) => sum + value, 0);
}

function lengths(words: string[]): Array<number> {
  return words.map((word) => word.length);
}

function flatten(rows: Array<number[]>): number[] {
  const all: number[] = [];
  for (const row of rows) {
    for (const value of row) {
      all.push(value);
    }
  }
  return all;
}

const numbers: Array<number> = [4, 1, 3];
const grid: Array<Array<number>> = [[1, 2], [3], []];
const words: string[] = ["tree", "a", "branch"];
const groups: Array<string[]> = [words, ["leaf"]];

grid[2].push(9);
groups[1].push("root");

const labels = numbers.map((n, i) => "#" + i + "=" + n);
const joined = numbers.reduce((text, n) => text + n, ">");
const start: Array<number> = [];
const sizes = words.reduce((acc, word) => {
  acc.push(word.length);
  return acc;
}, start);
const entry: Entry = { key: "k", counts: lengths(words) };

console.log(numbers, grid, groups, total(numbers), flatten(grid));
console.log(labels, joined, sizes, sizes === start, entry, total(entry.counts));
console.log(grid.map(total), groups.map((g) => g.join("/")), numbers.map((n) => n > 2));
