// At -o:speed opt calls a closure it sees made directly, copies the body of a small function into its
// caller, and takes a cell that is only read after it is made apart into its fields. The shapes here
// cross all three: several returns, a parameter that may be null, calls inside an inlined body,
// recursion, cells joined at a branch or carried around a loop, cells that must stay cells, and
// closures called where they are made or handed to a small function.

interface Vec {
  x: number;
  y: number;
  z: number;
}

interface Named {
  name: string;
  size: number;
}

interface Sized {
  size: number;
  extra?: number;
}

interface Body {
  pos: Vec;
  mass: number;
  open: boolean;
  label: number | string;
}

function vec(x: number, y: number, z: number): Vec {
  return { x: x, y: y, z: z };
}

function add(a: Vec, b: Vec): Vec {
  return { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z };
}

function scale(a: Vec, k: number): Vec {
  return { x: a.x * k, y: a.y * k, z: a.z * k };
}

function dot(a: Vec, b: Vec): number {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

function lengthSquared(v: Vec): number {
  return dot(v, v);
}

function same(v: Vec): Vec {
  return v;
}

function sign(x: number): number {
  if (x > 0) {
    return 1;
  }
  if (x < 0) {
    return -1;
  }
  return 0;
}

function pick(first: boolean): Vec {
  if (first) {
    return { x: 1, y: 2, z: 3 };
  }
  return { x: 4, y: 5, z: 6 };
}

function nameOf(item: Named | null): string {
  return item === null ? "none" : item.name;
}

function named(n: number): Named {
  return { name: "item" + n, size: n };
}

function body(x: number, open: boolean): Body {
  return { pos: vec(x, 0, 0), mass: 2, open: open, label: open ? "open" : x };
}

function grow(v: Vec): void {
  v.x += 1;
}

function isEven(n: number): boolean {
  return n === 0 ? true : isOdd(n - 1);
}

function isOdd(n: number): boolean {
  return n === 0 ? false : isEven(n - 1);
}

// Doubling a string allocates megabytes, enough for collections while a split cell's string lives
// only in a register or a stack slot.
function churn(): number {
  let s = "ab";
  for (let k = 0; k < 21; k++) {
    s = s + s;
  }
  return s.length;
}

function carried(): number {
  let acc = vec(0, 0, 0);
  const step = vec(1, 2, 3);
  let s = 0;
  for (let i = 0; i < 1000; i++) {
    acc = add(scale(acc, 0.5), step);
    s += dot(acc, step);
  }
  return s;
}

function largest(): string {
  let best: Named = { name: "", size: -1 };
  for (let i = 0; i < 5; i++) {
    const item = named((i * 7) % 5);
    best = item.size > best.size ? item : best;
  }
  const total = churn();
  return best.name + " " + best.size + " " + total;
}

// The literal leaves extra out, so the read before the write sees undefined.
function late(): string {
  const p: Sized = { size: 1 };
  const before = p.extra;
  p.extra = 3;
  return `${before} ${p.extra} ${p.size}`;
}

function twiceOver(f: (x: number) => number, x: number): number {
  return f(f(x));
}

let later: () => number = () => 0;

// watch has a loop, so it stays a call, and the closure it returns keeps the box of seen alive past
// the frame of inSight: its environment must go to the heap.
function inSight(n: number): string {
  let count = 0;
  const bump = (by: number): number => {
    count += by;
    return count;
  };
  bump(2);
  bump(3);

  let seen = 0;
  const watch = (times: number): (() => number) => {
    for (let i = 0; i < times; i++) {
      seen += i;
    }
    return () => seen;
  };
  later = watch(n);
  seen += 100;

  const pickOne = n > 2 ? (x: number) => x + 1 : (x: number) => x - 1;
  const alias = sign;
  return `${count} ${later()} ${pickOne(n)} ${alias(n)} ${twiceOver((x) => x * n, 2)}`;
}

function kept(): number[] {
  const list: Vec[] = [];
  for (let i = 0; i < 4; i++) {
    list.push(vec(i, i * 2, i * 3));
  }
  const p = vec(1, 2, 3);
  grow(p);
  p.y = p.x + p.z;
  const alias = same(p);
  return [lengthSquared(list[3]), p.x, p.y, alias === p ? 1 : 0];
}

console.log(sign(5), sign(-2), sign(0), sign(-0));
console.log(dot(pick(true), pick(false)), lengthSquared(add(vec(1, 1, 1), same(vec(2, 3, 4)))));
console.log(nameOf(named(3)), nameOf(null));
console.log(isEven(10), isOdd(7), isEven(3));
console.log(carried());
console.log(largest());
console.log(kept());
console.log(late());
const b = body(3, false);
const c = body(4, true);
console.log(b.pos.x + c.pos.x, b.mass, b.open, c.open, b.label, c.label);
console.log(vec(1, 2, 3), body(5, true));
console.log(inSight(4), inSight(1));
console.log(later());
