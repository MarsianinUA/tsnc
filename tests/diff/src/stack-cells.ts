// Cells opt puts on the stack at -o:speed hold the only reference to a string or an object of the
// heap while the program allocates enough to collect: the collector finds them by scanning the
// stack. The shapes after them keep their cells on the heap, and would print other numbers if one
// of those went on the stack.

interface Named {
  name: string;
  size: number;
}

interface Point {
  x: number;
  y: number;
}

interface Holder {
  item: Point | null;
}

// Doubling a string allocates megabytes in a few cells, enough for a collection now and then, and
// under TSNC_GC_STRESS for one at every cell.
function churn(): number {
  let s = "ab";
  for (let k = 0; k < 21; k++) {
    s = s + s;
  }
  return s.length;
}

function local(): string {
  const box = { label: "label " + churn(), count: 2 };
  churn();
  return box.label + " " + box.count;
}

function walked(): string {
  let joined = "";
  for (const part of ["a" + churn(), "b" + churn(), "c"]) {
    churn();
    joined += part + ";";
  }
  return joined;
}

function closures(n: number): string {
  let out = "";
  for (let i = 0; i < n; i++) {
    const tag = "t" + i * churn();
    const read = () => tag + "!";
    churn();
    out += read();
  }
  return out;
}

function describe(named: Named): string {
  churn();
  return named.name + " is " + named.size;
}

function passed(): string {
  const named = { name: "n" + churn(), size: 3 };
  return describe(named);
}

function sixteen(): number {
  let sum = 0;
  for (const v of [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]) {
    sum += v;
  }
  for (const v of [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]) {
    sum += v;
  }
  return sum;
}

// A pop shortens an array on the stack in place, down to undefined.
function popped(): number {
  const values = [1, 2, 3];
  let total = values.length;
  let last = values.pop();
  while (last !== undefined) {
    total = total * 10 + last;
    last = values.pop();
  }
  return total * 10 + values.length;
}

console.log(local());
console.log(walked());
console.log(closures(3));
console.log(passed());
console.log(sixteen(), popped());

// A cell that reaches the next pass through a phi: the next pass makes its own.
function chain(n: number): number[] {
  const out: number[] = [];
  let prev = { x: -1 };
  for (let i = 0; i < n; i++) {
    const cur = { x: i };
    out.push(prev.x);
    prev = cur;
  }
  return out;
}

// A cell of the inner loop held by one of the outer loop, which outlives the inner pass.
function nest(): number[] {
  const out: number[] = [];
  for (let i = 0; i < 3; i++) {
    const holder: Holder = { item: null };
    for (let j = 0; j < 3; j++) {
      const p = { x: i, y: j };
      if (j === 0) {
        holder.item = p;
      }
    }
    const first = holder.item;
    if (first !== null) {
      out.push(first.x * 10 + first.y);
    }
  }
  return out;
}

// A cell a callee keeps after the call returns.
let saved: Point | null = null;
function save(p: Point): void {
  saved = p;
}
function leak(): void {
  const p = { x: 5, y: 6 };
  save(p);
}
function overwrite(): number {
  const q = { x: 99, y: 98 };
  return q.x + q.y + churn();
}

// A cell a closure hands back out of its environment, after the frame that made it is gone.
function handedBack(n: number): Point {
  const p = { x: n, y: n + 1 };
  const get = () => p;
  return get();
}

console.log(chain(4), nest());
leak();
const handed = handedBack(5);
console.log(overwrite() > 0, saved, handed);
