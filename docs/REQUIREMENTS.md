# tsnc: requirements for a TypeScript to machine code compiler

Version 0.1 · September 15, 2026 · status: agreed (13-question interview, cross-checked against external sources and similar projects).

## 0. Summary in six points

- `tsnc` compiles a statically typed subset of TypeScript directly to machine code, like Go or Clang. It does not generate or support JavaScript.
- Written in Odin. LLVM 20 backend through the LLVM-C API, already in the Odin distribution (`E:\Odin\dist`). Linking goes through LLD from the same distribution on Windows and through the system C compiler on Linux and macOS, as Odin itself does.
- TypeScript is the single source of truth. Whatever cannot be compiled honestly and fast produces a compile error with file and line. There are no silent workarounds.
- Runtime in Odin: its own garbage collector (mark-sweep, without moving objects), UTF-16 strings, tagged values for `any` and union.
- The compiler is multithreaded: parsing and type checking run in parallel from the first version, code generation from the second.
- Compile time is not limited, the priority is the quality and speed of the generated code. Differential tests against Node check correctness.

## 1. Goal and scope

**What it is.** The `tsnc` compiler ("TypeScript Native Compiler") takes a TypeScript project and produces a native executable for Windows, Linux, and macOS. Inside: its own frontend (lexer, parser, type checking and inference), its own intermediate representation, LLVM IR generation, LLVM optimizations, linking.

**What it is not.**
- Not a transpiler: JavaScript does not appear in the output in any form.
- Not full TypeScript: it supports a subset that grows by version (section 2).
- Not a Node runtime: DOM, `fs`, `process`, npm packages are out of scope.

**Source of truth.** The semantics of constructs come from TypeScript. A valid `tsnc` program passes `tsc --strict` and fits the subset. Where `tsc` trusts the programmer without a check, `tsnc` adds a runtime check (3.8).

**Prior art.** Static Hermes (Meta) is the closest analog for number semantics and exact objects. AssemblyScript and Static TypeScript (MakeCode) are examples of subsets and runtimes. tsgo (Microsoft) is the model for parallel type checking. Go is the model for a non-moving garbage collector and a "source → machine code" pipeline.

## 2. TypeScript subset

### 2.1 Three feature levels

| Level | What it is | Policy |
|---|---|---|
| 1. Static | Types are known at compile time, objects have a fixed shape | Compiles directly, with no overhead. Fully in v1 |
| 2. Limited dynamic | `any`, union, index signatures, `Object.keys`, `obj[key]` | Compiles through the runtime at a known cost. In v1 only `any` and union as a tagged value; the rest in v2 |
| 3. Impossible without an interpreter | `eval`, `new Function`, prototypes, `arguments`, changing an object's shape through `as any` | Never. Compile error |

### 2.2 Contents by version

**v1**
- Declarations: `const`, `let`, `function`, arrow functions, closures, `export` / `import` (ESM, relative paths), `interface`, `type`.
- Primitives: `number`, `string`, `boolean`, `null`, `undefined`, literal types (`"circle"`, `42`, `true`).
- Strings: concatenation, template strings, `length`, indexing, basic methods (`charCodeAt`, `slice`, `indexOf`, `includes`, `split`, `trim`, `toUpperCase`, `toLowerCase`, `startsWith`, `endsWith`).
- Objects: literals, nesting, optional fields `x?: T`, `readonly`.
- Arrays: `T[]`, literals, indexing, `length`, `push`, `pop`, `indexOf`, `includes`, `slice`, `join`, `sort`, `map`, `filter`, `forEach`, `reduce`.
- Control flow: `if` / `else`, `switch`, `for`, `for...of`, `while`, `do...while`, `break`, `continue`, `return`, the ternary operator.
- Expressions: arithmetic, `===` / `!==`, comparisons, `&&` / `||` / `!` / `??`, bitwise operations, `typeof`.
- Union types and narrowing: by `typeof`, by `===` on a field with a literal type (discriminated unions), by `switch`, by a `null` / `undefined` check.
- Generics of built-in types (`Array<T>`, signatures like `map<U>`) are supported inside the checker; user-defined generics in v2.
- Standard library: `console.log`, `console.error`, `process.argv`, `process.exit`, `Math`, `Number` (`isInteger`, `parseFloat`, `toString`, `toFixed`), `String`.
- The list of string and array methods may grow within v1 if a method does not require new language mechanisms.

**v2**
- Classes (fields, constructor, methods, single inheritance, `this`), user-defined generics through monomorphization, `try` / `catch` / `throw`, `async` / `await`, destructuring, spread, `Map` / `Set`, `enum`, optional chaining `?.`, getters / setters, `export default`.
- Index signatures as hash tables, `Object.keys` / `for...in`, `obj[key]` access through a field-name table, full structural typing of objects (3.3), integer optimization of `number` (3.1), cross-compilation, debug info.
- Regular expressions (own engine for the ECMAScript dialect, 4.5), `bigint` (the arithmetic engine is `core:math/big` from the Odin standard library, the value itself is an immutable object in the GC heap), WebAssembly through WASI (`wasm-ld` is already in the Odin distribution), minimal file I/O (reading and writing a whole file, stdin).

**Never**
- `eval`, `new Function`, prototypes and `__proto__`, `arguments`, `with`, `var`, `namespace`, decorators, `Symbol`, `==` / `!=` with type coercion (3.7), adding and removing object fields after creation, `delete`.

### 2.3 Rule for everything else

Any construct outside the v1 list produces a compile error with file, line, column, and, where possible, a hint (for example, "use `===`"). The compiler never skips a construct silently and never replaces it with an approximate implementation. `tsnc check` lists all unsupported constructs in a program in one pass, so you can see how much code is outside the subset before rewriting.

## 3. Runtime semantics

### 3.1 Numbers
- `number` is always an IEEE 754 double (f64). The semantics are exact: `NaN`, `Infinity`, `-0`, fractional division, `%` as in TS, bitwise operations through conversion to int32.
- v2: an optimization the program cannot observe. The compiler proves that a value is always an integer in the safe range (loop counters, indices, results of bitwise operations) and keeps it in i64 / i32. Behavior does not change, only speed. Precedent: Static Hermes (Int32 / Uint32 as type refinements in the IR).
- Conversion to string follows ECMAScript `Number::toString` strictly: the shortest round-trip representation, decimal notation when `1e-7 <= |x| < 1e21`, exponential otherwise; `-0` prints as `0`.

### 3.2 Strings
- Immutable sequences of 16-bit units (UTF-16). `length`, `charCodeAt`, `slice`, and indexing match TS for any characters, including Cyrillic and emoji.
- Conversion to UTF-8 happens only at the OS boundary: console, files, arguments.
- Converting a function to a string (`String(f)`, `` `${f}` ``, `"a" + f`) is a compile error where the type says the value is a function, and a runtime error where it comes through a union or `any`: Node prints the function's source text, which a compiled program does not keep. Converting an object with its own `toString` field is a runtime error, since Node would call it, and so is `+` with an object that has its own `valueOf`, which `+` asks first.
- A string holds at most 536,870,888 units, as in Node 24. Building a longer one, by `+`, `join` or any other method, is a runtime error with Node's message, `Invalid string length`, where Node throws a `RangeError`.
- Inside the runtime, a string is a header in the GC heap followed by `u16` data; operations work through Odin's built-in `string16` type, which points inside the object. A custom "pointer plus length" pair is not needed, and the console re-encodes its line to UTF-8 on the way out (4.5).
- v2: hybrid Latin-1 / UTF-16 storage to save memory, as in V8. The semantics do not change.

### 3.3 Objects
- Each object type gets a fixed memory layout (a struct). The set of fields in canonical order (by name) determines the layout, so `Point` and `Vec2` with the same fields share one layout and are compatible at no cost.
- An object reference is 8 bytes, a field access is one load at a known offset.
- **Exact-type rule (v1).** An object is assignable only to a type with the same set of fields. Passing an object with more fields where fewer are expected (`{x, y, z}` into a parameter `{x, y}`) produces a compile error with a hint. Optional fields are part of the set and live in a tagged slot (3.4).
- Within one set of fields, a narrow object passes where a wider type is expected, as in TypeScript: `{x: number}` goes where `{x: number | string}` is expected. The value is the same object, not a copy, so `===` holds and a write through either type shows through the other. The compiler finds every such flow in the whole program and gives each class of types that flow into each other one layout; a field whose types differ across the class is a tagged slot. A read through the narrower type checks what the slot holds (3.8).
- v2: full structural typing. For inexact conversions the compiler generates a fat pointer (object + field offset table, similar to itab in Go); when layouts match, access stays direct.
- An object's shape does not change after creation: fields cannot be added or removed.

### 3.4 `any` and union
- A value of type `any` or a union takes 16 bytes: a type tag and a payload. `number`, `boolean`, `null`, `undefined` are stored inline without allocation; strings, objects, arrays, functions by pointer.
- Optional fields and `T | undefined` use the same representation.
- Type narrowing (`typeof`, a literal field, `switch`, comparison with `null`) compiles to a tag check. After narrowing, the value works as a statically typed one.
- `any` and `unknown` narrow by `typeof` as in tsc: inside `typeof x === "number"` the value is a `number`, while `"object"` and `"function"` leave it as it was.
- A value of type `any` can be printed, compared with `===`, tested for truth, turned into a string and given to a static type, with the check of 3.8. Whatever else JavaScript would do to it by converting it or looking something up at run time is a compile error that asks to narrow it first: arithmetic, `<` and the other orderings, reading a field, indexing, calling, `for...of`. So is an `any` that would become a function anywhere in the type it goes into, since only its tag could be checked, never its signature.
- v2: NaN-boxing down to 8 bytes as an optimization, only together with precise GC roots.

### 3.5 Functions and closures
- A function value is a pair (code pointer, environment pointer). Functions without captures have an empty environment.
- Captured variables that change after capture live in the heap; immutable ones are copied.
- `let` in a `for` header creates a new binding on each iteration: closures in a loop capture different `i`.
- All calls resolve statically; an indirect call goes only through a function value.
- Every function takes its environment as the first argument, null when it captures nothing, so a direct call, a call through a function value and a call from the runtime (a sort comparator) pass arguments the same way. A boolean travels as a 64-bit word and a tagged value as two words, as they do into the runtime.
- A function passes where a function type that holds an argument or the result differently is expected, as in TypeScript: `(x: number | string) => void` goes where `(x: number) => void` is expected, and `() => number` where `() => void` is. The value is the same function, not a wrapper, so `===` holds. The compiler finds every such flow in the whole program and gives each class of function types that flow into each other one signature; an argument or a result whose type differs across the class travels tagged, and the function reads it back through its own declared type with a check.

### 3.6 Arrays
- `T[]` is a growable contiguous buffer with a length and a capacity, with unboxed elements (`number[]` is an array of f64).
- `push` is amortized O(1). Arrays have no holes.
- `map`, `filter`, `forEach` and `reduce` follow Node when the callback changes the array: the length is read once, and `forEach`, `filter` and `reduce` stop where the array now ends. `map` over an array its callback shortens is a runtime error (3.8), because Node would leave a hole. `reduce` of an empty array without an initial value is a runtime error with Node's message, `Reduce of empty array with no initial value`.

### 3.7 Equality
- `===` / `!==`: primitives by value, strings by content, objects by reference.
- `==` / `!=`: only if the types of both sides match statically; then it is `===`. Otherwise a compile error with a hint.

### 3.8 Checks where tsc is unsafe

Where `tsc` trusts the programmer without a check, `tsnc` adds a runtime check instead of returning `undefined` against the static type:
- reading `arr[i]` out of range or with a non-integer index: runtime error;
- writing `arr[i]`: when `i === arr.length`, append to the end, beyond that an error;
- `x!`: a check, error on `null` / `undefined`;
- reading a field through its declared type when a write through a wider type of the same object (3.3) left a value that type does not allow: runtime error;
- a read the checker narrowed, and an `any` or a union given to a static type: the tag is checked, and for an object or an array its layout, so a value that came through `any`, or changed after the test that narrowed it, is a runtime error. The check is shallow: a layout is a shape, so two object types of one layout, such as `{kind: "a", v: number}` and `{kind: "b", v: number}`, pass for each other, and an `as` to a literal type checks the tag only;
- `as`: widening and union narrowing with a runtime tag check are allowed; `as any`, `as unknown as T` are forbidden;
- division by zero and overflow follow f64 semantics (`Infinity`, `NaN`), without errors.

A runtime error in v1 (before `try` / `catch` exist) writes a message to stderr with the error name and, where available, the source location, and exits with code `1`. Programs that behave differently in Node in these cases are invalid and stay out of the differential tests.

### 3.9 Console output
- `console.log` and `console.error` print what Node's `util.format` prints. A string first argument is a format string while more arguments follow it, with Node's specifiers `%s %d %i %f %j %o %O %c %%`. Every other argument follows after a space: a string as is, anything else as `util.inspect` prints it with Node's defaults (depth 2, 80 columns, 100 array items, 10000 string units, long arrays grouped into columns, cycles marked `<ref *1>` and `[Circular *1]`). The line and its newline leave in one write.
- Numbers per 3.1, `undefined` / `null` / `boolean` as words, arrays and objects as `[ 1, 2, 3 ]` and `{ a: 1, b: 'x' }`, functions as `[Function: f]`.
- One exception to 3.1, and it follows Node: a negative zero printed on its own keeps its sign. Node formats an argument of `console.log` through `util.inspect` rather than through `String`, so `console.log(-0)` writes `-0` while `` console.log(`${-0}`) `` writes `0`.
- An object prints its fields in the order Node enumerates them: integer-like keys in ascending order, then the rest in creation order. An optional field that was never set is left out. So is one set to `undefined` explicitly, which Node prints as `y: undefined`: v1 cannot tell the two apart. An optional field that the literal left out and the program set later prints after the fields the literal wrote, in canonical order, where Node prints fields in the order they were set.
- Where Node would run the program's own code to print a value, the program stops with a runtime error (3.8): `%s`, `%i` or `%f` of a function or of an object with its own `toString`, `%d` of an object with its own `valueOf` or `toString`, `%j` of an object with its own `toJSON`.
- Colors follow Node: `FORCE_COLOR`, `NO_COLOR`, `NODE_DISABLE_COLORS` and `TERM`, then whether the stream is a terminal. On Windows a console gets escape sequence processing turned on, as libuv does. The column width of a character, which groups an array, comes from Unicode 17 East Asian Width; unlike Node, a sequence that NFC would compose, such as Hangul jamo, is counted as it is.
- `process.argv` is the path of the executable, the first argument as the process was started, then the arguments, which is what a Node single executable application sees. On Windows the arguments come from the wide command line, so any alphabet arrives intact.
- Output is UTF-8 regardless of the Windows console code page.

## 4. Compiler architecture

### 4.1 Pipeline
1. **Lexer.** TypeScript tokens, template strings with nesting, automatic semicolon insertion (ASI) per the specification.
2. **Parser.** Hand-written recursive descent (like tsc and Go). Builds an AST with positions for diagnostics. Parses type syntax: union, arrays, object types, function types, literal types, `Array<T>`.
3. **Semantic analysis.** Name and module resolution, type checking and inference (section 5), union narrowing, subset checking. The result is a typed AST.
4. **Custom IR.** A low-level representation with explicit layouts, tags, and runtime calls. The place for custom optimizations (v2: integer narrowing, escape analysis for closures, objects, and arrays: a value that does not leave its function goes on the stack or splits into separate variables and never reaches the GC heap).
5. **Code generation.** IR → LLVM IR through the LLVM-C API in memory, not as text. LLVM optimizations through the new pass manager (`LLVMRunPasses`, pipelines `default<O2>` / `default<O3>`). Object file through `LLVMTargetMachineEmitToFile`.
6. **Linking.** On Windows, `lld-link` from the Odin distribution. On Linux and macOS, the system C compiler (`cc`) as the linker driver, as Odin and Rust do: only it knows where the C runtime startup files, the dynamic loader, and the SDK live on a given machine. It links the program object file, the runtime object file, and system libraries. Flags come from `odin build -print-linker-flags`.

### 4.2 LLVM
- The LLVM version is pinned: 20.x, the same `LLVM-C.dll` that ships with Odin. Changing the major version is a separate task.
- The LLVM-C bindings are our own: generated from the LLVM 20 headers with `odin-c-bindgen` or written by hand for the needed subset. No suitable ready-made bindings exist: the existing ones target LLVM 17 and 22, and the API changed between versions (opaque pointers, removal of the legacy pass manager, `LLVMConst*`).
- The project's first smoke test: "hello world" built through the bindings into an object file and linked into an executable.
- The `-emit-llvm` flag outputs textual LLVM IR for debugging.

### 4.3 Runtime
- Written in Odin, built ahead of time for each platform into an object file (`odin build runtime -build-mode:obj`) and linked with the program.
- The runtime owns the entry point: Odin initializes its context and allocators, then calls the generated symbol `tsnc_main`. Manual initialization of the Odin runtime is not needed.
- Exports functions for generated code as `proc "c"` under the symbol names of `abi`: allocation, GC, strings, arrays, tagged values, console, runtime errors. They are external symbols kept with `@(require)` and strong linkage, not `@(export)`: on Windows that is dllexport, and the executable would carry an export table with the temporary output name in it. Each exported function sets the Odin context first.
- Contents: the garbage collector (section 6), UTF-16 strings and their methods, arrays, number formatting, console output, error handling. Section 4.5 defines what comes from the Odin standard library and what the project writes itself. `Math` is not part of the runtime: the code generator emits LLVM intrinsics directly (4.5).

### 4.4 Compiler memory
- Arenas per phase and per thread; no per-object freeing. This is idiomatic for Odin and removes questions about allocator thread safety.

### 4.5 Odin standard library

General rule: the project reuses `core` wherever it conflicts with neither the GC heap nor ECMAScript semantics. The compiler and the runtime follow different defaults, because they work with memory in different ways.

**The compiler uses `core` freely.** It is an ordinary Odin application, and there is no reason to hide the standard library from it. Key packages: `core:mem/virtual` (the growing arenas of section 4.4), `core:thread` (section 8), `core:flags` (Odin-style CLI, section 9), `core:container/topological_sort` (module initialization order and import-graph partitions for the checkers), `core:strings`, `core:slice`, `core:hash` (name interning), `core:fmt` and `core:log` (diagnostics), `core:os` (files, running the linker, and Node in tests). The frontend's structure follows `core:odin` (`tokenizer`, `parser`, `ast`): the code is not reused, since the language is different, but the AST layout in an arena and the positions inside tokens work the same way.

**The runtime uses `core` along the memory-ownership boundary.** All of `core` is built on explicit allocators: what it creates belongs to the caller, and the collector does not trace it. Hence the rule:
- everything that **holds references to TS values** lives in the GC heap, and the project writes it: objects, array buffers, closures, string cells, `Map` and `Set` hash tables (v2). The runtime never uses Odin's built-in `map` and `[dynamic]` for program data: the collector would not see references inside them;
- everything that **holds no references** comes from `core` where `core` gives Node's answer at the same cost: decimal arithmetic, hashing, page reservation, console output. Where a `core` algorithm answers differently or costs more, the project writes its own: the shortest digits of a number, the repair of broken UTF-8, sorting with a comparator.

The GC heap never becomes `context.allocator`. Allocating a TS value is always an explicit call with a type table; a hidden allocation from `core` in the GC heap would be untyped and invisible to marking. Each exported procedure sets up the runtime `context` on entry (4.3): `allocator` is the call's scratch arena, `temp_allocator` resets when the call ends, `assertion_failure_proc` produces a runtime error per 3.8.

**Semantics always follow ECMAScript.** Where `core` has a procedure with the same name but different rules, `core` works as the engine underneath, and the project writes the TS layer on top. Numbers already work this way: `core:strconv/decimal` does the exact decimal arithmetic, and the shortest digits, the `1e21` and `1e-7` thresholds and the reading of long literals are ours. The same applies to string case (`toUpperCase` by full Unicode rules, where `ß` becomes `SS`), number parsing (`parseFloat`), string comparison by 16-bit units, and sort order.

| What | From `core` | Ours |
|---|---|---|
| GC heap pages | `mem/virtual.reserve`, `commit` (both `contextless`) | size classes, object-start map, marking and sweeping |
| Strings | built-in `string16`, `unicode/utf16`, the byte ranges of `unicode/utf8` | cell in the GC heap, methods from 2.2, UTF-8 decoding that turns each broken sequence into one U+FFFD as `Buffer.toString` does, full case rules from tables generated from the Unicode Character Database (the tables of `core:unicode` are from an old Unicode version and stop at the BMP) |
| Numbers to string and back | `strconv/decimal` (exact expansion, shifts, rounding), `strconv.decimal_to_float_bits` | `Number::toString` rules (3.1), `ToNumber` grammar, the shortest digits (Go's current `roundShortest`: the copy in `core:strconv` predates two of its fixes), the digits of a literal past the 384 that `decimal.set` keeps, an exact comparison with the halfway point for a literal of more than 190 significant digits |
| Array sorting | nothing | a natural merge sort over indices into a temporary copy, in the manner of TimSort: n - 1 comparator calls for sorted or reversed input, as in V8; comparator rules, `undefined` to the end, the order of strings without a comparator |
| Console | `core:os` for the streams, the environment and the terminal check | output format per 3.9: a port of `util.format` and `util.inspect`, color rules, a column width table generated from the Unicode Character Database, and the UTF-16 to UTF-8 encoding of the line (`io.write_string16` writes one character per call) |
| Objects, arrays, closures, `Map`, `Set` | nothing | everything, layout shaped for GC type tables |
| `Math` | nothing, see below | only differences from C |
| `bigint` (v2) | `math/big` as the arithmetic engine with an explicit allocator | immutable object in the GC heap, digits copied at creation |
| `RegExp` (v2) | nothing | `core:text/regex` is not the ECMAScript dialect: no lookahead, lookbehind, or backreferences |

**`Math` bypasses the runtime.** `core:math` itself declares LLVM intrinsics (`llvm.sqrt.f64`, `llvm.pow.f64`, and others). A runtime call for `Math.sqrt` would be a wrapper around a wrapper and would kill constant folding, inlining, and vectorization. The code generator emits the intrinsic directly; functions without an intrinsic (`tan`, `atan2`, `cbrt`, `hypot`) go to libm, which is linked anyway. Only the differences from C go into the runtime: `Math.round` rounds a half toward positive infinity, `Math.max` and `Math.min` have their own rules for `NaN` and `-0`.

## 5. Type inference and checking

- The input must pass `tsc --strict`. `tsnc` does not reproduce all tsc diagnostics, but it must reject everything outside the subset and everything that does not type-check in its model.
- Inference is local, as in tsc: variable type from the initializer, return type from the function body, array element type from the literal, literal types for `const`.
- Contextual typing: arrow function parameters get their type from the expected signature (`arr.map(x => x * 2)`, `x: number`).
- Instantiation of generic signatures of built-in types: `map<U>` infers `U` from the body of the passed function.
- Union narrowing: `typeof`, also of `any` and `unknown`, `===` on a field with a literal type, `switch` on such a field, `null` / `undefined` checks, `!`.
- Object compatibility by the exact-type rule (3.3), primitives and union by TS rules.
- Diagnostics: several errors per pass, format `file:line:col: error[T0123]: text`, a stable error code from a registry in the repository, each code with a hint on how to rewrite; with parallel checking the output order is deterministic.

## 6. Memory management

- A custom garbage collector written in Odin, part of the runtime. Objects never move: a deliberate limitation, Go does the same.
- **v1:** mark-sweep, stop-the-world. The collector finds stack roots conservatively (it treats every stack word that looks like a heap address as a pointer); it scans the heap precisely using type tables that the compiler generates for each layout (which slots hold pointers or tagged values).
- **v2:** concurrent tri-color marking with write barriers in generated code, as in Go. No pause requirements until v2.
- Consequences of the conservative scan that are mandatory in v1:
  - a size-class allocator with pages and an object-start map, so that a pointer into the interior of an object (LLVM creates them) finds its owner;
  - before the stack scan, a per-platform assembly stub flushes callee-saved registers to memory (V8 / Oilpan and druntime do this);
  - generated code does not disguise pointers: no arithmetic on them outside the runtime, no NaN-boxing in v1;
  - mitigating the risk of "external" derived pointers from LLVM optimizations: loop strength reduction is disabled (`-disable-lsr`), the base pointer stays live across calls. The risk cannot be fully eliminated and is accepted: Chrome (Oilpan) and Firefox live with it in production.
- Fallback if the conservative scan does not work out: a custom shadow stack (the compiler generates a frame record with references and a per-thread frame list), as in Static Hermes and AssemblyScript. The project does not use LLVM's built-in shadow stack (`llvm.gcroot`): it is slow and not thread-safe.
- The GC heap holds closures, strings, arrays, objects, and tagged values with pointers. A v1 program is single-threaded, with one mutator.

## 7. Modules and the compilation unit

- The compilation unit is the whole program, like a crate in Rust. One entry file, and the compiler builds the graph from relative `import`s itself.
- One LLVM module and one executable per program. This gives inlining across file boundaries, dead code elimination, and simple type tables for the GC.
- ESM only: `export`, `import { x } from "./m"`, `import * as m from "./m"`. Imports from `node_modules` and by bare specifiers are not supported.
- Import cycles are allowed for types and functions. Top-level module code runs once in dependency order; a cycle between modules with top-level side effects is a compile error.
- No incremental build in v1.

## 8. Compiler multithreading

- **v1.** A thread pool from `core:thread`. Parsing of all files runs in parallel, one task per file. Type checking runs on several checkers over import-graph partitions, as in tsgo: each checker owns its caches, there is no shared mutable state, and the result and the diagnostic order are deterministic. Code generation into one LLVM module on one thread.
- **v2.** The compiler splits the program into N codegen units, optimizes each on its own thread (its own `LLVMContext`, module, and `TargetMachine`), and links the object files with ThinLTO, as in Rust.
- Rule from day one: no global mutable state, all passes receive context explicitly. Global LLVM settings (`LLVMParseCommandLineOptions`) are set once before the pool starts.
- The `-j:N` flag sets the number of threads; the default is the number of cores.

## 9. Platforms, CLI, artifacts

- Target platforms: Windows x64, Linux x64, macOS arm64 and x64. The compiler and the runtime are portable and build natively on each OS; the target is a parameter (target triple, linker, runtime OS layer through `core:os`). v2 adds WebAssembly through WASI (`wasm32-wasi`, linking with `wasm-ld`).
- Cross-compilation is out of scope for v1: Linux from Windows becomes reachable in v2 through `ld.lld` from the Odin distribution and a sysroot or static musl, without third-party tools; macOS requires the Apple SDK and signing, native build only.
- Testing on three OSes through GitHub Actions: `windows-latest`, `ubuntu-latest`, `macos-latest` (arm64), `macos-26-intel` (x64).
- CLI modeled on Odin:

```sh
tsnc build src/main.ts -out:dist/app.exe            # optimized build
tsnc build src/main.ts -out:dist/app.exe -o:none    # no optimizations, for debugging
tsnc run src/main.ts                                # build and run
tsnc check src/main.ts                              # check only, no code generation
tsnc build src/main.ts -emit-llvm -out:dist/app.ll  # textual LLVM IR
tsnc build src/main.ts -emit-ir -out:dist/app.ir    # custom IR dump for debugging
tsnc build src/main.ts -target:linux_amd64 -j:8     # target and number of threads
tsnc build src/main.ts -sanitize:address            # link the runtime built with AddressSanitizer
```

- Artifacts: an executable; on request, an object file, textual LLVM IR, and a custom IR dump. Debug info (PDB / DWARF) in v2.
- Third-party tools: LLVM and LLD from the Odin distribution, plus the system C compiler on Linux and macOS for linking (Odin needs it there too). Only the tests need Node and `tsc`, as a reference; they take no part in the build.

## 10. Quality and verification

- **Differential tests.** Each test is a `.ts` file. The reference is `node test.ts` (Node 24 strips types without flags; the v1 subset is fully "erasable"). The test compares stdout, stderr, and the exit code byte for byte with `dist/test.exe`. Size: two to three dozen programs of our own, one per construct from section 2; each new feature adds its own test. For `enum` in v2 the reference goes through `tsc` → JS → `node`.
- **Checks on third-party code.** Once per version, several real small TS programs run through `tsnc check` to show what the subset rejects in practice.
- **Gate.** Each test first passes `tsc --noEmit --strict`; TypeScript is a dev dependency in the tests folder.
- **Negative tests.** A file with an expected compile error: the test checks the error code, line, and column.
- **Unit tests.** Lexer, parser, checker, number formatting, GC through `odin test`.
- **GC stress mode.** A runtime flag that runs a collection on every allocation and checks heap integrity after each collection. The differential tests also run in this mode.
- **AddressSanitizer.** A separate CI test run builds the runtime with `-sanitize:address` and runs the differential tests against it in GC stress mode. The collector poisons the memory of its heap that no cell owns, as Go's sweep does under ASan, so a runtime read past the end of a cell or into the body of a freed one stops the program.
- **Benchmarks.** A set of programs (numeric loops, strings, arrays of objects, closures, allocations) against Node and Go equivalents, plus startup time and exe size for hello world. The repository records results per version, with no hard limits.
- **Infrastructure smoke test.** "Hello world" through the LLVM-C bindings and the linker, runs in CI on three OSes.
- **v1 acceptance criterion.** The reference set of programs in the v1 subset passes the differential tests on Windows, Linux, and macOS in CI; the GC survives a stress test with allocations and closures in a loop without leaks or crashes.

## 11. Non-functional requirements

- Compile time is not limited; the priority is the quality and speed of the generated code. Target: on numeric and array-heavy tasks, comparable to Node already in v1 and closer to Go after the v2 integer optimization; on strings and allocations, lagging behind Node in v1 is acceptable, and benchmarks record the gap.
- Building the compiler: `odin build src -out:dist/tsnc.exe -o:speed -vet -strict-style`, following the `projects/odin-template` template. `-vet -strict-style` are mandatory.
- No global mutable state; deterministic output for any number of threads.
- Runtime errors in the generated program always come with a message and exit code `1`, never silent continuation.
- All repository text is in English: documentation, code comments, identifiers, and compiler messages.
- Repository structure of `E:\Odin\projects\tsnc`: `src/` compiler, `src/runtime/` runtime, `src/llvm/` bindings, `tests/` (unit, differential and negative), `bench/`, `dist/`, `docs/` project documentation (requirements, architecture plan, task board, development guide).

## 12. Explicitly out of scope

None of the following is planned in any version; section 2 lists everything planned, by version.

- JavaScript generation in any form.
- npm, `node_modules`, `paths` from `tsconfig.json`, imports by bare specifiers.
- Node and browser APIs beyond the minimum (in v1 `console`, `process.argv`, `process.exit`; in v2 minimal file I/O): DOM, `fetch`, `http`, timers, `child_process`, `crypto`.
- `eval` and any dynamic code generation; a built-in interpreter for `any`.
- Decorators, `Symbol`, `namespace`, prototypes (full list in section 2, "Never").
- Multithreading inside the compiled program (Worker, shared memory).
- Incremental build and compilation cache.
- Language server and IDE integration.

## 13. Open risks

| Risk | What to do |
|---|---|
| LLVM-C bindings are tied to a specific version, and the API changes between major versions | Pin LLVM 20, generate bindings automatically, smoke test in CI |
| "External" derived pointers from LLVM optimizations under the conservative scan | Mitigations from section 6, GC stress tests under `-O3`, the shadow stack fallback |
| The exact-type rule will reject part of ordinary TS code | Collect a corpus of real programs and measure the rejection rate before v2; offset tables in v2 |
| macOS is tested only in CI | Connect GitHub Actions early |
| Numbers as f64 in v1 are slower than Go on integer tasks | Optimization in v2, benchmarks record the gap |
| The name `tsnc` matches the abandoned project `mhw0/tsnc` ("typescript native compiler", C, archived since 2024) and the command of the commercial TSN.1 Compiler (Protomatics). The name is free on npm, crates.io, PyPI, JSR, Homebrew, and AUR; the `tsnc` username on GitHub is taken | Acceptable for a personal project; when publishing, state "TypeScript → machine code, Odin + LLVM" in the description to stand apart in search |
| Exact reproduction of the Node format in `console.log` for objects | `util.inspect` is ported rule by rule and tested against Node's output; a Node release that changes it needs the port changed too, and the corpus shows where |
| The runtime relies on the built-in `string16` from a nightly Odin build | The Odin version is pinned together with LLVM 20; on rollback a custom "pointer plus length" pair is enough, and the semantics of 3.2 do not change |

## 14. Sources and prior art

- Static Hermes: typed mode, exact objects, number as double with Int32 refinements, precise GC roots. https://github.com/facebook/hermes/blob/static_h/doc/TypedLanguage.md
- AssemblyScript: explicit integer types, nominal interfaces, ITCMS and shadow stack. https://www.assemblyscript.org/runtime.html
- Static TypeScript (MakeCode): conservative stack and precise heap, the cost of access through an interface. https://www.microsoft.com/en-us/research/blog/rocket-fast-embedded-typescript-for-makecode-arcade/
- TypeScript-Go: parallel checkers over import-graph partitions. https://devblogs.microsoft.com/typescript/typescript-native-port/
- LLVM: garbage collection and its limitations. https://llvm.org/docs/GarbageCollection.html
- LLVM-C: PassBuilder and TargetMachine. https://llvm.org/doxygen/llvm-c_2Transforms_2PassBuilder_8h_source.html
- bdwgc: conservative scanning, interior pointers. https://github.com/bdwgc/bdwgc
- Oilpan (V8 / Chromium): flushing registers before the stack scan. https://chromium.googlesource.com/v8/v8/+/main/include/cppgc/README.md
- Odin: context and exporting `proc "c"`. https://www.gingerbill.org/article/2025/12/15/odins-most-misunderstood-feature-context/
- Node.js: running TypeScript with type stripping. https://nodejs.org/api/typescript.html
- ECMAScript `Number::toString`. https://tc39.es/ecma262/multipage/ecmascript-data-types-and-values.html#sec-numeric-types-number-tostring
- Go: non-moving garbage collector, concurrent marking. https://go.dev/doc/gc-guide
- odin-c-bindgen for generating bindings. https://github.com/karl-zylinski/odin-c-bindgen
- Odin standard library: package documentation. https://pkg.odin-lang.org/
- Odin: `core:unicode/utf16` and the built-in `string16` type. https://pkg.odin-lang.org/core/unicode/utf16/
