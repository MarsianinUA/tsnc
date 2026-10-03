# Performance review, October 2026

A working file: the evidence, the numbers and the probes behind tasks T6.15 to T6.27 of the [task board](tasks-tsnc.md), so that the tasks can stay short. T6.28 deletes it.

The review of 2026-10-03 read `lower`, `opt`, `codegen` and the runtime at `dev` after T6.14 with one question: which decisions of the design, as opposed to single missed cases, keep a compiled program slower than what the compiler knows before run time allows. It ran small programs against Node and Bun and read how scriptc represents values.

## How the numbers were taken

Intel Core i5-13600KF, Windows 11, Node 24.13.1, Bun 1.4.2, scriptc 0.2.1. A probe is one file from [Probes](#probes), built with `tsnc build <probe>.ts -o:speed` and run as it is by `node` and `bun`. A number is the shortest of five to seven runs: the wall time of the whole process in milliseconds, started from Git Bash. That includes starting the process, about 25 ms for a tsnc executable and about 70 for Node, so a short probe understates a ratio. `-emit-ir` at `-o:speed` shows what `opt` left of a function, and `-emit-llvm` prints the module after LLVM's passes.

## The numbers

| probe | what it does | tsnc | Node | Bun | task |
| --- | --- | ---: | ---: | ---: | --- |
| `bsearch` | binary search in a `number[]` | 6878 | 949 | 1096 | T6.15, T6.16 |
| `hash` | a hash with a bitwise or over a `number[]` | 4458 | 1198 | 1819 | T6.15, T6.17 |
| `hash-local` | the same hash over the loop counter | 216 | 1299 | 1795 | |
| `mask` | a bitwise and over elements | 865 | 223 | 189 | T6.15, T6.17 |
| `field-counter` | a counter in a field, taken modulo 8 | 1022 | 338 | 352 | T6.17 |
| `sieve` | `bench/ts/sieve`, 2 million flags, 5 rounds | 134 | 254 | 141 | T6.16, T6.26 |
| `sieve-small` | the same work on 250 thousand flags, 40 rounds | 94 | 179 | 105 | T6.26 |
| `num2str` | `String(i % 1000)`, 10 million times | 574 | 110 | 52 | T6.18 |
| `num2str-frac` | `String` of a fraction, 5 million times | 1533 | 381 | 239 | T6.18 |
| `upper` | `toUpperCase` of a 7-unit word, 10 million times | 541 | 286 | 192 | T6.18 |
| `append` | 120 thousand `s += "x"` | 550 | 80 | 39 | T6.19 |
| `concat3` | `a + ":" + b`, 10 million times | 230 | 93 | 83 | T6.19 |
| `vec` | vector math through objects a function returns | 214 | 248 | 216 | T6.20 |
| `vec-scalar` | the same math on variables | 81 | 123 | 88 | |
| `fib` | `fib(40)` | 412 | 697 | 453 | |
| `fib-callback` | the same after an unrelated callback flow | 435 | 686 | 451 | T6.22 |
| `shapes` | a `switch` over `kind` of a union of three objects | 148 | 352 | 254 | T6.23 |
| `sum` | a sum over a `number[]` | 210 | 270 | 224 | |
| `sum-widened` | the same after one widening flow of another array | 358 | 267 | 221 | T6.24 |
| `raytracer` | `bench/ts/raytracer` | 311 | 487 | 501 | |
| `raytracer-widened` | the same after one widening flow of a `Vec` shape | 368 | | | T6.24 |
| `trees` | `bench/ts/trees` | 349 | 345 | 293 | T6.27 |
| `trees-short` | the same without the long-lived tree | 239 | 334 | 318 | T6.27 |

Where tsnc already leads, for scale: `particles` (fields of objects in an array) 148 against 386 and 243, `matmul` (nested arrays) 77 against 146 and 119, `callback` (a function value called in a loop) 268 against 1078 and 433, `optional` (an optional number field) 354 against 568 and 455, `union-call` (a `number` passed to a parameter that is a number or a string) 150, the same as with a plain `number` parameter.

## How others pass a narrow value where a wide one is expected

- V8 (Node) has no static types: every value carries its kind. An array has an elements kind (small integers, doubles, anything), and one array moves to a wider kind when a store needs it. A field has a representation per hidden class, widened the same way. Nothing changes for the other arrays and objects of the program.
- JavaScriptCore (Bun) keeps an indexing type per array the same way, and a value is one NaN-boxed word of 8 bytes, so a mixed array is no wider than an array of numbers.
- scriptc 0.2.1 copies. A union value is a reference-counted box on the heap (`ScrUnion` in its `scr_runtime.h`). Passing a `number[]` as an array of numbers or strings calls a generated function that builds a new array and boxes every element, and an object is rebuilt the same way. The copy breaks aliasing: a probe that pushes through the wide type prints `4 3` where Node prints `4 4`. Its numbers are always f64, and it has no escape analysis.
- Java and C# let a `String[]` pass as an `Object[]`. A read is free, and a store checks the element's type (`ArrayStoreException`, `ArrayTypeMismatchException`).
- tsnc keeps the value one value, as Node does, and decides the layout once for the whole program (requirements 3.3, 3.5, 3.6). Finding 7 is what that costs.

## Findings

### 1. A double becomes an int32 the long way (T6.15)

`to_int32` in `src/codegen/numbers.odin` spells ECMAScript's ToInt32 of a double in full: truncate, take the remainder by 2^32, fold twice, convert with saturation. Every operand of `|`, `&`, `^`, `~` and the shifts that `opt` did not prove an integer goes through it. V8 and JavaScriptCore convert with one truncating instruction and take the long way only when it overflows: for a double below 2^63 in magnitude, the low 32 bits of the truncation to 64 bits are the answer. `bsearch`, `hash` and `mask` are four to seven times behind Node because of it; `hash-local`, where the operands are proved integers, is six times ahead.

### 2. Nothing bounds an array's length (T6.16)

`length_limit` in `src/opt/ranges.odin` caps the length of a string at `abi.MAX_STRING_LENGTH` and the length of an array at 2^53 - 1. So `length + 1` may pass the safe range, and it stays a double: every `push` converts the length to f64, adds, and converts back (`sitofp`, `fadd`, `fptosi` around `set_length` in `-emit-llvm` of `sieve`), and the length travels through memory, so the chain is carried from one pass to the next. A copy of `bench/ts/sieve` that only pushes took 64 ms in a run where the whole program took 109. In `bsearch`, `(lo + hi) >> 1` has `hi` from `a.length - 1`, so the sum is a double too and takes the long way of finding 1. With a bound on the length, the existing narrowing keeps both in integers.

### 3. A number in memory is never a known integer (T6.17)

`ranges` proves integers for SSA values, globals, parameters of functions no function value names, and results of direct calls. A number loaded from a field or an array element has no range, and neither has a parameter of a function used as a value. So `a[i] & 15` converts a double on every pass (`mask`), `(c.n + c.step) % 8` is a float remainder followed by a checked conversion to an index (`field-counter`), and `(x * 2) % 1000003` in an arrow of `bench/ts/closures` is an `frem`. The whole-program fixpoint that already covers globals and parameters can cover a field of a layout and the element of an array layout: when every store into the slot is an integer in range, a load is one.

### 4. Number to string builds a 384-digit decimal (T6.18)

`to_string` in `src/runtime/num/format.odin` fills a `decimal.Decimal` for every number, an integer too, and rounds it with `round_shortest`; `src/runtime/str/number.odin` then reads the UTF-8 result in two passes. An integer costs about 55 ns against 4 in Node (`num2str`), a fraction about 300 against 60 (`num2str-frac`), and that is 51 of the 208 ms of `bench/ts/strings`. Go, whose `roundShortest` the code follows, tries Ryu first and keeps this path as the fallback; V8 has a path for integers and a cache.

`map_case` in `src/runtime/str/case.odin` decodes code points and looks each one up in the Unicode tables twice, for ASCII text too: 39 more ms of `strings`, and `upper` at twice Node's time.

### 5. Every `+` on strings copies both sides (T6.19)

`concat` in `src/runtime/str/str.odin` makes a flat copy, and `lower_concat` and `lower_template` in `src/lower/strings.odin` emit one call per `+` or per piece of a template. So `a + ":" + b` allocates twice (`concat3`), a template with two numbers makes five cells, and `s += x` in a loop copies the whole string on every pass: 30, 60 and 120 thousand appends take 34, 135 and 530 ms, where Node stays near 5. V8 and JavaScriptCore make a rope and flatten it on the first read; scriptc appends in place when the reference count is 1.

### 6. A small object a function returns is always a heap cell (T6.20, T6.21)

`escape` runs per function and before any inlining. LLVM inlines `add` and `scale` later, but it cannot delete the allocation, which by then is a pop of the heap's free list. `vec` runs at 214 ms against 81 for the same math on variables; Node and Bun have the same gap. In `raytracer`, 16 inline allocation sites are left in `intersect` and 15 in `trace`; the measurement of T6.14 put the `Vec` and `Hit` temporaries at about 5% of its time.

A call through a function value is indirect even when the function is in sight: `const add = (y) => y + i; made += add(i % 10)` in `bench/ts/closures` is a `make_closure` and a `call_closure` in one block. Once small functions are inlined, `apply(times, f, start)` meets its `f` the same way.

### 7. A widening flow changes every value of that shape (T6.24)

`build_classes` in `src/lower/types.odin` joins the layouts of two types that flow into each other, for the whole program, and the joined slot is tagged: 16 bytes, and a tag test at every read through the narrow type. Three things follow.

- One flow of any `number[]` into an array of numbers or strings tags every `number[]` of the program: `sum-widened` is 1.7 times slower than `sum` and falls behind Node, for a line that touches another array.
- A few lines at the end of `bench/ts/raytracer/main.ts` that pass a `Vec`-shaped object where its `x` may be a string too slow the whole program from 311 to 368 ms.
- The key of a class is shallow: field names and slot kinds, where a string, a function and an object are all a reference slot. So types that never meet join. In `strangers`, `Label {pos: string}` passed where `pos` may be a number tags `Body {pos: Vec}`, and `b.pos.x` becomes a tag test, an unbox and a layout test.

A single value pays nothing: a `number` passed to a parameter that is a number or a string is boxed at the call and unboxed in the callee, and LLVM folds both (`union-call`).

The direction: the wide side pays. A value keeps the layout it was made with; a place of the wide type holds one of several layouts, told apart by the table id in the cell's header, and a read through it dispatches and boxes what it loads. What is left is a write through the wide type of a value the narrow slot cannot hold. Three candidates:

- join the classes as today, but only where such a write can reach a narrow value, which needs a flow analysis and changes no behaviour;
- fail at that write, as Java and C# do, which moves the error of requirements 3.8 from a later read to the write and so rejects programs Node runs;
- for arrays only, move that one array to the tagged layout at the write, as V8 does, with a test of the header before a loop over the narrow type.

What stands in the way today: an `ir.Type` names one layout per reference, and `coerce` in `src/lower/expressions.odin` refuses a reference of another layout. A deeper class key, which tells a string slot from an object slot, removes the `Label` and `Body` case alone and keeps the layout a function of structure.

### 8. A function's signature follows its class, in direct calls too (T6.22)

`signature_of` in `src/lower/types.odin` gives every declared function the signature of its class, the class is keyed by the IR signature, and a direct call passes the class's positions. So one flow changes functions that never meet it. In `fib-callback`, `note(x: number): number` passed as `(x: number) => void` makes `fib(n: number): number`, which no function value names, return a tagged value: 412 to 435 ms. A tagged parameter or result also has no range, so the integers of finding 3 stop there.

The sort adapter is the precedent for the other way round: the function keeps its declared signature, and a function value carries the code of an adapter with the class's signature that converts and calls it. One adapter per function, so the value is still one cell and `===` holds.

### 9. A union of object types is a tagged value (T6.23)

`representation` in `src/lower/types.odin` makes any union of two or more object types a 16-byte tagged value, although the header of every cell already names its layout. Every read of a member's field repeats a tag test, an unbox and a layout test (`union_field_place` in `src/lower/unions.odin`). An element of a `Solid[]` is 16 bytes. A literal passed to a parameter of the union type is boxed, and a boxed cell counts as escaping, so it goes to the heap where the same literal passed as its own type stays on the stack. T6.5 made the union of one reference type with `null` a pointer; the same works for several reference types, with the header telling them apart.

By itself the gain is small: `shapes` is already 2.4 times faster than Node, and the measurement of T6.14 put the `switch` over `kind` in `raytracer` under 3%. It is the mechanism finding 7 needs.

### 10. LLVM is told nothing about memory (T6.25)

Every field and element access is a GEP over `i8` with no alias metadata, and `declare_runtime` in `src/codegen/module.odin` gives a runtime function no attribute but `noreturn`. So after each store of an element LLVM loads the array's length and elements pointer again (the inner loop of `sieve`), `a[i] = a[i] * k` does not vectorize, and a call into the runtime, a cold one too, makes every global be loaded again (`text` in `bench/ts/chars`). The store `a[i] = v` adds to it: the appending case of requirements 3.8 puts a call to `tsnc_array_reserve` into every such loop. What the alias information would gain is not measured.

### 11. An element of `boolean[]` is 8 bytes (T6.26)

`abi.SLOT_SIZE` gives a boolean slot 8 bytes, in an array too. The 2 million flags of `sieve` are 16 MB a round, against 2 MB in Go, and the same number of pushes and marks on arrays that fit the cache runs 30% faster (`sieve-small`).

### 12. Every collection pays for everything alive (T6.27)

A collection marks every live cell, and `sweep_page` in `src/runtime/gc/collect.odin` reads every slot of every page and writes each dead or free one into a free list again. `trees` spends 125 of its 349 ms in 35 collections (71 marking, 54 sweeping); without the long-lived tree it takes 239 ms, 41 of them in the collector. T6.8 weighed generations and left them out; this is the number for what the long-lived set costs. JavaScriptCore's collector does not move cells and scans the stack conservatively, as this one does, and has generations through sticky mark bits and a write barrier; Go keeps mark bits beside the page and sweeps by swapping them, with no free list to write.

## Seen and left out

- `collatz` runs in doubles: `x = 3 * x + 1` has no bound (requirements 3.1), and a proof would need a parity fact plus a guarded integer copy of the loop. tsnc already leads Node and Bun there.
- A number that may be `undefined`, and an optional number field, are 16 bytes. NaN-boxing would make them 8, at about 250 references in `abi`, `lower`, `codegen` and the runtime, and requirements 3.4 tie it to precise roots. `optional` already leads Node and Bun.
- A module `const` read in a function costs a load of its `$ready` flag and a branch in the IR, and the global is loaded on every read. LLVM hoists both: 140 ms against 139 with the values passed as parameters. Look again after T6.25.
- The runtime as bitcode linked into the program's module, so that small exports inline: with epic E7.8.
- One-byte strings: epic E7.12.
- Shared fields of a union's members at one offset: the layout must stay a function of structure.
- `find_free_run` in `src/runtime/gc/heap.odin` scans the page table for every large cell; the only path of the allocator that grows faster than linearly, and a small one.

## Checked and fine

A union of one reference type with `null` or `undefined` is a pointer. `number[]` holds f64. An object's header is 8 bytes and its slots 8 each. Direct calls pass a null environment that LLVM drops, and generated functions are internal, so LLVM picks their calling convention. Arrow callbacks of `map`, `filter`, `forEach` and `reduce` are inlined. String literals are interned, so a discriminant that matches is one pointer compare. Narrowed integer arithmetic carries `nsw`, and a proved bounds check is one compare. Failure blocks end in a `noreturn` call. The collector skips strings and arrays of numbers, marks heap slots without the owner lookup, and allocation is inline. The pass pipeline is LLVM's `default<O2>`. Code at the top level of a module runs as fast as the same code in a function.

## Probes

Each block is one file. A probe with a second name takes the change its line names.

`bsearch`:

```ts
function find(a: number[], key: number): number {
  let lo = 0, hi = a.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const v = a[mid];
    if (v === key) return mid;
    if (v < key) lo = mid + 1; else hi = mid - 1;
  }
  return -1;
}
function main(): void {
  const a: number[] = [];
  for (let i = 0; i < 1000000; i++) a.push(i * 2);
  let t = 0;
  for (let i = 0; i < 20000000; i++) t += find(a, (i * 7) % 2000000);
  console.log(t);
}
main();
```

`hash`; `mask` has `h = (h + (a[i] & 15)) & 65535` as the body of the inner loop; `hash-local` drops the array and runs `h = (h * 31 + i) | 0` 300 million times:

```ts
function main(): void {
  const a: number[] = [];
  for (let i = 0; i < 1000000; i++) a.push(i & 255);
  let h = 0;
  for (let r = 0; r < 300; r++) {
    for (let i = 0; i < a.length; i++) h = (h * 31 + a[i]) | 0;
  }
  console.log(h);
}
main();
```

`field-counter`:

```ts
interface Counter { n: number; step: number }
function main(): void {
  const c: Counter = { n: 0, step: 3 };
  const hist: number[] = [0, 0, 0, 0, 0, 0, 0, 0];
  for (let i = 0; i < 200000000; i++) {
    c.n = (c.n + c.step) % 8;
    hist[c.n] += 1;
  }
  console.log(hist.join(","));
}
main();
```

`sieve-small` is `bench/ts/sieve/main.ts` with `LIMIT = 250000` and `ROUNDS = 40`. `trees-short` is `bench/ts/trees/main.ts` with `build(1)` for the long-lived tree.

`num2str`; `num2str-frac` has `String(i * 0.37 + 0.11)` and 5 million passes:

```ts
let total = 0;
for (let i = 0; i < 10000000; i++) {
  const s = String(i % 1000);
  total += s.length;
}
console.log(total);
```

`upper`; `concat3` has `words[i & 3] + ":" + words[(i >> 2) & 3]` in place of the call:

```ts
const words: string[] = ["item523", "item5", "item999", "item12"];
let total = 0;
for (let i = 0; i < 10000000; i++) {
  total += words[i & 3].toUpperCase().length;
}
console.log(total);
```

`append`:

```ts
let s = "";
for (let i = 0; i < 120000; i++) {
  s += "x";
}
console.log(s.length);
```

`vec`; `vec-scalar` keeps `ax`, `ay`, `az` in variables and writes the same arithmetic out:

```ts
interface Vec { x: number; y: number; z: number }
function add(a: Vec, b: Vec): Vec { return { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z }; }
function scale(a: Vec, k: number): Vec { return { x: a.x * k, y: a.y * k, z: a.z * k }; }
function dot(a: Vec, b: Vec): number { return a.x * b.x + a.y * b.y + a.z * b.z; }
function main(): void {
  let acc: Vec = { x: 0, y: 0, z: 0 };
  const step: Vec = { x: 1, y: 2, z: 3 };
  let s = 0;
  for (let i = 0; i < 30000000; i++) {
    acc = add(scale(acc, 0.5), step);
    s += dot(acc, step);
  }
  console.log(s);
}
main();
```

`fib-callback`; `fib` is its first line and `console.log(fib(40))`:

```ts
function fib(n: number): number { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
function each(items: number[], f: (x: number) => void): void {
  for (let i = 0; i < items.length; i++) f(items[i]);
}
let seen = 0;
function note(x: number): number { seen += x; return seen; }
each([1, 2, 3], note);
console.log(fib(40), seen);
```

`shapes`:

```ts
interface Circle { kind: "circle"; r: number }
interface Rect { kind: "rect"; w: number; h: number }
interface Tri { kind: "tri"; b: number; h: number }
type Shape = Circle | Rect | Tri;
function area(s: Shape): number {
  switch (s.kind) {
    case "circle": return 3 * s.r * s.r;
    case "rect": return s.w * s.h;
    case "tri": return 0.5 * s.b * s.h;
  }
}
function main(): void {
  const shapes: Shape[] = [];
  for (let i = 0; i < 999; i++) {
    const m = i % 3;
    if (m === 0) shapes.push({ kind: "circle", r: i });
    else if (m === 1) shapes.push({ kind: "rect", w: i, h: 2 });
    else shapes.push({ kind: "tri", b: i, h: 3 });
  }
  let t = 0;
  for (let r = 0; r < 100000; r++) {
    for (let i = 0; i < shapes.length; i++) t += area(shapes[i]);
  }
  console.log(t);
}
main();
```

`sum-widened`; `sum` is the same without `describe` and the last two lines of `main`:

```ts
function sum(a: number[]): number {
  let s = 0;
  for (let i = 0; i < a.length; i++) s += a[i];
  return s;
}
function fill(n: number): number[] {
  const a: number[] = [];
  for (let i = 0; i < n; i++) a.push(i * 0.5);
  return a;
}
function describe(items: (number | string)[]): number {
  return items.length;
}
function main(): void {
  const a = fill(2000000);
  let t = 0;
  for (let r = 0; r < 200; r++) t += sum(a);
  console.log(t);
  const other: number[] = [1, 2, 3];
  console.log(describe(other));
}
main();
```

`raytracer-widened` is `bench/ts/raytracer` with these lines at the end of `main.ts`:

```ts
function labelHeight(v: { x: number | string; y: number; z: number }): number {
  return v.y;
}
console.log(labelHeight(addScaled({ x: 1, y: 2, z: 3 }, { x: 1, y: 1, z: 1 }, 2)));
```

`strangers`, read with `-emit-ir`: layout 1 holds `pos` tagged, and `move` tests it twice.

```ts
interface Vec { x: number; y: number }
interface Body { pos: Vec }
interface Label { pos: string }
function show(l: { pos: string | number }): void { console.log(l.pos); }
const lab: Label = { pos: "a" };
show(lab);
function move(b: Body): number { return b.pos.x + b.pos.y; }
console.log(move({ pos: { x: 1, y: 2 } }));
```
