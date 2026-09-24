// Arrays (requirements 3.6 and the Array methods of 2.2): literals, reading and writing an element,
// a write at the length appending, the methods the runtime answers, and map, filter, forEach and
// reduce, whose callbacks take the index and the array too. Arrays nest and hold objects, and
// for...of walks to the end the array has when it gets there.

interface Point {
  x: number;
  y: number;
}

const numbers = [3, 1, 2];
numbers[numbers.length] = 10;
numbers[0] = numbers[1] + numbers[2];
console.log(numbers, numbers.length, numbers[3]);
console.log(numbers.push(4, 5), numbers.pop(), numbers.indexOf(2), numbers.indexOf(99));
console.log(numbers.includes(10), numbers.slice(1, 3), numbers.slice(-2), numbers);

const words = ["pear", "apple", "fig"];
console.log(words.join(), words.join(" + "), words.sort(), words);

const mixed: (number | string)[] = [1, "two", 3];
console.log(mixed, mixed.includes("two"), mixed.indexOf(3), mixed.pop(), mixed);

const doubled = numbers.map((n, i) => n * 2 + i);
const counted = words.map((w, i, all) => w + i + all.length);
const long = words.filter((w) => w.length > 3);
let visits = 0;
numbers.forEach((n, i, all) => {
  if (all.length > 100) {
    return;
  }
  visits += n * i;
});
const total = numbers.reduce((sum, n) => sum + n, 0);
const product = numbers.reduce((a, b) => a * b);
const longest = words.reduce((best, w) => (w.length > best.length ? w : best), "");
console.log(doubled, counted, long, visits, total, product, longest);

const grid = [[1, 2], [3, 4, 5]];
grid[1][0] = 30;
grid[0].push(6);
console.log(grid, grid.map((row) => row.length), grid[1][2]);

const points: Point[] = [{ x: 1, y: 2 }, { x: 3, y: 4 }];
points.push({ x: 5, y: 6 });
points[0].x = 10;
console.log(points, points.map((p) => p.x + p.y), points.filter((p) => p.x > 3).length);

let sum = 0;
for (const n of numbers) {
  sum += n;
}
for (const p of points) {
  sum += p.y;
}
const growing = [1];
for (const n of growing) {
  if (n < 5) {
    growing.push(n + 1);
  }
}
console.log(sum, growing);

const args = process.argv.slice(2);
const empty: string[] = [];
console.log(args, args.length, empty, empty.join("-"), empty.pop());
