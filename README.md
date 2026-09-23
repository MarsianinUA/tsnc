# tsnc

tsnc compiles a statically typed subset of TypeScript straight to machine code, the way Go or Clang do. No JavaScript in between, no engine inside the executable. Written in Odin on top of LLVM.

A tsnc program is ordinary TypeScript. It passes `tsc --strict`, and the tests compare the compiled program's output with Node byte for byte. What can't be compiled honestly is a compile error with a file, a line and a hint on how to rewrite it. Nothing is silently approximated.

This is a personal project at an early stage. [Status](#status) says what builds today.

## Example

```ts
// fib.ts
function fib(n: number): number {
  if (n < 2) {
    return n;
  }
  return fib(n - 1) + fib(n - 2);
}

console.log("fib(30) =", fib(30));
console.log(0.1 + 0.2, 1e21, 7 / 2);
```

```sh
$ tsnc build fib.ts
$ ./fib
fib(30) = 832040
0.30000000000000004 1e+21 3.5
```

`node fib.ts` prints the same two lines.

## What a compiled program is

- One native executable for Windows x64, Linux x64 or macOS on arm64 and x64. It runs without Node and without a JavaScript engine.
- tsnc's own garbage collector manages memory. It is a stop-the-world mark-sweep that never moves an object.
- `number` is always a 64-bit float with the JavaScript rules: `NaN`, `-0`, `%`, bitwise operators through int32. Numbers print the way Node prints them.
- Strings are UTF-16, so `length`, `charCodeAt` and indexing agree with Node on Cyrillic and emoji. Output is UTF-8.
- Every object type has a fixed memory layout. A field read is one load at a known offset, and an object's shape never changes after creation.
- `any` and unions are a 16-byte tagged value. Narrowing by `typeof`, by a literal field or by a `null` check compiles to a tag check.
- Where `tsc` takes your word for it, tsnc checks at run time. `arr[i]` out of range or `x!` on `null` stops the program with a message and exit code 1 instead of handing back `undefined`.

## The TypeScript subset

**v1.** `const`, `let`, functions, arrow functions and closures. `number`, `string`, `boolean`, `null`, `undefined` and literal types. Object literals, `interface` and `type`, optional and `readonly` fields. Arrays with `push`, `pop`, `slice`, `join`, `map`, `filter`, `reduce` and a few more. Union types with narrowing, discriminated unions included. `if`, `switch`, `for`, `for...of`, `while`, `do...while`. Template strings. ESM `import` and `export` by relative path. From the standard library: `console.log`, `console.error`, `process.argv`, `process.exit`, `Math`, and the basic `Number` and `String` methods.

**v2.** Classes, user-defined generics, `try` / `catch`, `async` / `await`, destructuring, spread, `Map` and `Set`, `enum`, optional chaining, regular expressions, `bigint`, WebAssembly, file I/O.

**Never.** `eval`, `new Function`, prototypes, `arguments`, `with`, `var`, `namespace`, decorators, `Symbol`, `delete`, `==` between different types, adding a field to an object after creation.

Anything else is a compile error, and `tsnc check` reports all of them in one pass. [Requirements, section 2](docs/REQUIREMENTS.md#2-typescript-subset) has the full list.

## Limits

- No npm, no `node_modules`, no bare imports. A program is one entry file plus what it imports by relative path.
- No Node or browser APIs beyond `console`, `process.argv` and `process.exit`. No `fs`, timers, `fetch` or DOM.
- Object types are exact in v1. Passing `{x, y, z}` where `{x, y}` is expected is a compile error. Full structural typing is v2.
- `as any` and `as unknown as T` are rejected. `as` may widen a type or narrow a union, and tsnc checks the narrowing at run time.
- A compiled program runs on one thread, and the v1 collector pauses it while it works.
- tsnc builds for the machine it runs on. No cross-compilation, debug info or incremental builds yet.

## Status

Milestones 1 to 4 of the six that make up v1 are done. `tsnc check` covers the whole v1 subset and reports syntax, type, name and module errors in one pass. `tsnc build` and `tsnc run` produce executables for numbers, booleans, string literals, functions, control flow, modules, `Math`, `console` and `process.exit`.

Milestone 5 is next: the garbage collector, string operations, objects, arrays, closures and unions. Until then a program that uses one of them gets a compile error with a location, not a wrong executable. There are no benchmarks yet. They come with milestone 6. The [task board](docs/tasks-tsnc.md) tracks the rest.

## Usage

There are no prebuilt binaries. [Development](docs/development.md) explains how to build tsnc from source with Odin and LLVM 20.

```sh
tsnc build src/main.ts                      # writes main.exe on Windows, main elsewhere
tsnc build src/main.ts -out:dist/app.exe    # optimized build under a chosen name
tsnc build src/main.ts -o:none              # no optimizations, for debugging
tsnc run src/main.ts                        # build and run, exit with the program's code
tsnc check src/main.ts                      # report errors, generate nothing
```

`-emit-llvm` and `-emit-ir` write LLVM IR or tsnc's own IR as text instead of an executable.

## Docs

- [Requirements](docs/REQUIREMENTS.md) cover the subset, runtime semantics, the CLI and the quality bar.
- [Architecture plan](docs/architecture-plan-tsnc.md) describes the packages, their contracts and the milestones.
- [Task board](docs/tasks-tsnc.md) lists the tasks with dependencies and done criteria.
- [Development](docs/development.md) explains building from source, the tests, CI and the repository layout.
