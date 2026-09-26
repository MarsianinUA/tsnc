# Architecture plan: tsnc

Paradigm: direct
Status: ready for detailed planning
Created: September 17, 2026
Repository root: `E:\Odin\projects\tsnc`. This document lives in `docs/` next to `REQUIREMENTS.md` and `tasks-tsnc.md`.
Requirements: `REQUIREMENTS.md` v0.1. This document does not repeat them, it only links to sections.

## Planning readiness

- Interview stage complete: yes (REQUIREMENTS.md plus four decisions confirmed by the user).
- Key decisions made before writing: yes.
- Remaining unknowns marked as optional assumptions: yes.
- Decision map confirmed by the user: yes.

## Goal

The overall architecture of the whole application: which modules the compiler and the runtime split into, how the modules interact, and what single principle stands behind that interaction. The architecture covers v1 and v2 at once (requirements, 2.2), and implementation proceeds by milestone. Next, the document gets cut into tasks.

## What must be true when done

- Every package is named; it has one entry point, and we know what it owns, what it hides and what it depends on.
- The import graph points only up the pipeline, with no cycles.
- Every v2 feature is mapped to the packages that change and to what v1 already provides for it.
- The next step is clear: `$direct-plan` for one milestone from the "Milestones" section.

## Repository context

- Project template: `projects/odin-template`. Build with `odin build src -out:dist/... -o:speed -vet -strict-style`, no build scripts, `.exe` on all platforms, `dist/.gitkeep` keeps the directory.
- Distribution `E:\Odin\dist`: Odin `dev-2026-09-nightly:a2fb372`, `LLVM-C.dll`, `bin/lld-link.exe` (one LLD binary, flavor as a parameter), `bin/wasm-ld.exe`.
- Frontend precedent: `dist/core/odin` splits into `tokenizer`, `parser`, `ast`; an AST node is positions plus a `derived` union, and the data lives apart from parsing.
- Verified `core` building blocks: `thread.Pool` (`pool_add_task` takes a task allocator), `mem/virtual.Arena` (`arena_init_growing`), `os.process_start` and `os.process_exec`, `container/topological_sort`, `flags`, the built-in `string16` in `base:runtime`.
- The project has no principles file, so `$direct-principles`, `$design-language` and `$code-conventions` apply in full.

## Architecture drivers

Requirements that shape the structure (REQUIREMENTS.md section in parentheses):

- No global mutable state; output is deterministic for any `-j` (8, 11).
- Parsing and type checking run in parallel from v1; codegen into N units with ThinLTO in v2 (8).
- Arenas per phase and per thread, no per-object freeing (4.4).
- The target is a parameter: three OSes in v1, cross-compilation and `wasm32-wasi` in v2 (9).
- Diagnostics: several errors per pass, stable codes with hints, `tsnc check` lists everything in one pass (2.3, 5).
- The runtime is a separate object file, exports are `proc "c"`, the GC heap never becomes `context.allocator` (4.3, 4.5).
- Conservative stack scan plus a precise heap via type tables; shadow stack as the fallback (6).
- Nothing silent: an unsupported construct is a compile error, a runtime error is stderr and exit code 1 (2.3, 3.8).
- Correctness is checked differentially against Node (10).
- The whole program is one compilation unit and one LLVM module (7).

## Architecture in brief

tsnc is two Odin products: the `tsnc.exe` compiler and the runtime object file. One package, `abi`, ties them together; it describes cell layouts, tags, GC type tables and the list of runtime exports. The compiler is a pipeline of seven transformations: `parse` → `bind` → `program` → `check` → `lower` → `codegen` → `link`. Each transformation is a package with one entry point that takes the frozen data of the previous layer and an allocator, and returns a new data layer and a list of diagnostics. The only imperative package, `driver`, owns the thread pool, arenas, files and processes, and connects the phases; `main` parses flags and prints. Parallelism is fork-join over frozen input with results indexed by `File_ID`, so the output does not depend on the thread count. The three type worlds have three owners: TS types in `check`, IR layouts in `ir`, LLVM types in `codegen`; translation happens only at the entry of the next phase. The runtime repeats the same pattern: `abi` as the contract, `gc` as the sole owner of program memory, the other packages as operations on cells, the exports as a thin shell.

## Philosophy: a pipeline of frozen layers

Eight rules. Every package and every milestone is checked against them.

1. **A phase is a pure transformation.** Input: immutable data from previous layers plus an allocator. Output: a new data layer plus diagnostics. A phase does not read files, print, start processes or touch threads.
2. **A layer is frozen after creation.** No one modifies the result of a previous phase. New facts live in separate tables keyed by stable identifiers: `File_ID`, `Node_ID`, `Symbol_ID`, `Type_ID`, `Func_ID`, `Layout_ID`. That is why many threads can read one AST without races.
3. **Imports point only up the pipeline.** A consumer imports a producer for the shape of its result. `ast` and `ir` are split out as separate data packages because each has three consumers and independent tools live around them: traversal, printing, verification.
4. **One imperative layer.** Only `driver` owns the thread pool, arenas, the file system, temporary files and external processes. Only `main` prints and sets the exit code.
5. **Parallelism is fork-join.** `driver` hands out pure tasks (a file, a graph partition, a codegen unit) and waits for all of them. Results go into arrays indexed by `File_ID`, and diagnostics are sorted by position, so the output is the same at `-j:1` and at `-j:32`.
6. **Diagnostics are data.** A phase does not stop at the first error: it returns a partial result (a `Bad` node, an error type) and a list of diagnostics. An infrastructure failure (a file cannot be read, the linker crashed) is a package enum error that `driver` translates into its own.
7. **Three type worlds, three owners.** TS types belong to `check`, IR layouts and types belong to `ir`, LLVM types belong to `codegen`. A layout is a pure function of the canonical structure of a TS type, so two checkers that built `Point` and `Vec2` independently get one layout without sharing data.
8. **A subset rule lives in the earliest phase that can decide it.** `parse` rejects `var` and decorators, `check` rejects `==` between different types and an extra object field, all with a code from the `diag` registry.

The runtime follows the same rules with one documented exception: it has exactly one piece of package-level state, the heap: a `gc.Heap` that `rt` holds, while `gc` itself keeps no state and its procedures take the heap as a parameter. The `proc "c"` exports do not receive a heap parameter, and a v1 program is single-threaded.

## Precedents

Adopted:

- `core:odin` from the distribution: AST data apart from parsing, a node with positions and a `derived` union, files and nodes in an arena. We take the shape, not the code.
- tsgo (https://devblogs.microsoft.com/typescript/typescript-native-port/): checkers per import graph partition, each with its own caches, no shared mutable state. We take the "private type table per checker" model.
- tsc: a separate binder (symbols, scopes, a flow graph for narrowing) before the checker. We take it as the boundary between `bind` and `check`.
- Go (`go/ast`, `go/types`, SSA in `cmd/compile`): data packages with one producer and many consumers, SSA in flat arrays. We take this for `ast` and `ir`.
- Static Hermes (https://github.com/facebook/hermes/blob/static_h/doc/TypedLanguage.md): exact objects, numbers as double with integer refinements in the IR. We take it as the model for optimization at the `opt` level.
- Go GC, Oilpan, bdwgc: non-moving mark-sweep, register flush before the stack scan, an object start map. Architecturally this gives the `gc` package with a per-platform assembly stub.
- LLVM new pass manager via `LLVMRunPasses`: the only path in LLVM 20, affects only `codegen`.
- Odin (`src/linker.cpp`) and Rust: on Linux and macOS the system C compiler drives the linker, because only it knows where the C runtime startup files, the dynamic loader and the SDK live on a given machine. We take it for `link`.

Rejected:

- `llvm.gcroot` and the LLVM built-in shadow stack: slow and not thread-safe (requirements, 6). The fallback is our own, through `abi`, `codegen`, `gc`.
- A shared type table with locks: breaks "no shared mutable state" and kills determinism.
- LLVM IR as the only intermediate representation: leaves no place for our own v2 optimizations and the explicit checks they remove.
- `core:text/regex`: not the ECMAScript dialect (requirements, 4.5).

## Key decisions

The detailed planner and the writer stop and ask before changing any row.

| Subject | Decision | Reversibility | Reason | Consequence |
| --- | --- | --- | --- | --- |
| Single interaction principle | Pipeline of frozen layers, the eight rules above | Irreversible | No shared mutable state, determinism, the data path is visible in one `driver` procedure | Every phase package has exactly one entry point of the form "data plus allocator → data plus diagnostics" |
| Owner of I/O and threads | Only `driver`; only `main` prints | Irreversible | Unit tests cover pure phases without files or processes | Phases receive file text and paths as values |
| Shape of check facts | The AST is immutable after `parse`; facts live in tables keyed by `Node_ID` | Irreversible | Parallel checkers without races; `lower` reads facts as arrays | Every node has a dense `Node_ID` within its file, every file has a `File_ID` |
| Parallel checkers (confirmed) | A private type table per checker, a file's facts refer to its own checker's table, no merge step | Reversible: a merge can be added later | As in tsgo; the layout has to be a function of structure anyway (requirements, 3.3) | `lower` interns layouts by a canonical key; a `Type_ID` has meaning only paired with its table |
| Shape of our own IR (confirmed) | An SSA graph of basic blocks in flat arrays, references through `distinct` indices, every instruction has a position | Irreversible | The code generator becomes one exhaustive `switch` with no knowledge of TS; v2 optimizations are data-flow analyses; the dump for `-emit-ir` is trivial | Everything implicit in TS becomes an explicit IR instruction: tag check, bounds check, reference store, runtime call |
| Built-in types (confirmed) | An embedded `lib.d.ts` in TypeScript, hidden module number zero; `lower` matches the implementation by name | Reversible | One type description language instead of two; v2 extends the file | `parse` handles `declare` and generic interfaces; `check` rejects `declare` outside the lib file |
| Name binding (confirmed) | A separate `bind` package, one task per file together with parsing | Reversible | tsc has proven the boundary; the work is strictly per file, so it runs in parallel | `check` receives the frozen `Bound_File` of all modules |
| Compiler and runtime contract | One `abi` package, imported by both sides | Irreversible | The single source of truth for layouts, tags, type tables, export names; linking and differential tests catch any mismatch | The runtime imports a compiler package; `abi` imports nothing but `base` |
| Program data umbrella | The `program` package: files, AST, `Bound_File`, module graph, initialization order; frozen before `check` | Reversible | `check` and `lower` read one value; the module graph is a pure function of the import lists | The import discovery loop with file reading lives in `driver`; sorting and cycle detection live in `program` |
| Compiler memory | A phase takes `allocator` as its last parameter; `driver` provides an arena per task and per phase, everything lives until the end of the build | Reversible | Requirements, 4.4; a phase result belongs to an arena, not to individual objects | Not a single `free`; temporary data goes through the thread's `context.temp_allocator` |
| Codegen unit | `codegen` takes a `Unit` (a slice of `Func_ID`) from day one; in v1 there is one unit | Reversible | v2 cuts the program into N units and optimizes them in the pool without changing the entry point | `Program_IR` knows the split into units only as data |
| Target platform | The `target` package as data: triple, linker, link flags, runtime object name, pointer size | Reversible | Cross-compilation and wasm in v2 add a row to the table | `codegen` and `link` take a `Target` value as a parameter |
| Runtime memory | The GC heap is the only package-level state; `context` is set up at the entry of every `proc "c"` export | Irreversible | Requirements, 4.3, 4.5, 6 | Allocating a TS value always takes a type table identifier; `core` only for data without references |
| Errors | A diagnostic as a value with a code from the `diag` registry; infrastructure failures as a package enum | Irreversible | Requirements, 5; `tsnc check` in one pass | A phase keeps working after an error and returns a partial layer |

Alternatives considered:

- A tsc-style `Program` umbrella that all phases append facts to. Rejected: it breaks rule 2 and needs locks.
- `lex` as a separate package. Rejected: tokens have one consumer. The lexer is a public stage of `parse` (`tokenize`) with its own tests.
- A wrapper over LLVM-C with Odin-style names. Rejected as pass-through: `codegen` is the only consumer of the raw bindings and is itself the adapter.

## Package boundaries: compiler

Directory `src/`, package `main` at the root. The table order is the pipeline order and the allowed import direction.

| Package | Purpose | Entry point | Owns | Hides | Depends on | Deletion test |
| --- | --- | --- | --- | --- | --- | --- |
| `source` | Source file table and positions | `File_ID`, `Span` (file, start, end), converting a position to line and column | File text, normalized paths | The line break table | `core` | Passes: `ast`, `diag`, `ir`, `main` need positions |
| `diag` | Error code registry and diagnostics as values | `Diagnostic` (code, span, arguments), sorting, rendering to `file:line:col: error[T0123]: text` plus a hint | The code enum, the message and hint table, the sort order | Text templates | `source` | Passes: otherwise every phase would have to learn to print |
| `ast` | Syntax tree nodes of one file | `File_AST` (file, nodes with a dense `Node_ID`, import list), traversal | Node shapes for expressions, statements, types; `Bad` nodes; all nodes of a file in one array, a child is its `Node_ID` (T2.3) | Nothing: the data is fully readable | `source` | Passes: three consumers (`bind`, `check`, `lower`) |
| `parse` | Text to AST | `parse_file(text, File_ID, allocator)` returns `File_AST` and diagnostics; the `tokenize` and `parse_tokens` stages are public | Tokens, one array per file that `tokenize` returns and `parse_tokens` reads (T2.4), automatic semicolon insertion, nested template strings, recursive descent, type syntax, syntactic subset rules | Tokenizer and parser state | `ast`, `diag`, `source` | Passes |
| `bind` | One file's AST to symbols and scopes | `bind_file(^File_AST, allocator)` returns `Bound_File` and diagnostics | The file's symbol table, the scope tree, import and export tables, the control flow graph for narrowing, the "has top-level side effects" flag | The traversal algorithm | `ast`, `diag` | Passes: otherwise every checker binds other files again |
| `program` | The whole frozen program | `Program` (file table, AST and `Bound_File` by `File_ID`, import edges, initialization order, `File_ID` of the lib module); graph construction | Module graph, topological order, strongly connected components, the rule "a cycle with side effects is an error" | The search that produces both (Tarjan's strongly connected components over the import edges; `core:container/topological_sort` orders by hash table traversal, which changes between runs, and finds no components) | `source`, `ast`, `bind`, `diag` | Passes: two consumers, `check` and `lower` |
| `check` | Type checking and inference for a program partition | `check(^Program, partition []File_ID, allocator)` returns `Check_Result` and diagnostics | TS types and their table (one per call), type inference, contextual typing, instantiation of generic built-in types, union narrowing, the exact-type rule, semantic subset rules, a `Typed_File` for each file in the partition | Type interning and caches | `program`, `bind`, `ast`, `diag`, `source` | Passes |
| `abi` | Contract between generated code and the runtime | Data types: cell header, tags, tagged value, string, array, closure and environment cells; the GC type table format; the `Runtime_Proc` enum with names and signatures; the closure calling convention; the `tsnc_main` name; runtime error codes | Every number both sides must know identically | Nothing | `base` | Passes: otherwise layouts get duplicated in `lower`, `codegen` and the runtime |
| `ir` | Our own intermediate representation | `Program_IR` (functions, interned layouts, module global cells, string pool, GC type tables, initialization order, units), `Func` (blocks, SSA instructions, values), builder, printer for `-emit-ir`, verifier | The closed set of IR types (`F64`, `Bool`, `Tagged`, `Ref(Layout)`, `Str`, `Closure`, in v2 `I32` and `I64`) and instructions: arithmetic, branches, `phi`, allocation, field load and store, `store_ref`, element access with an explicit bounds check, tag check, boxing and unboxing, call, closure call, runtime call, intrinsic, failure with a code and a position | Nothing: the data is fully readable | `source`, `abi` | Passes: three consumers (`lower`, `opt`, `codegen`) |
| `lower` | Typed program to IR | `lower(^Program, []Check_Result, allocator)` returns `Program_IR` and diagnostics | All TS semantics in IR terms: control flow, closures and capture (mutable ones on the heap, immutable ones by copy), a new `let` binding on every iteration, narrowing as a tag check, boxing into a union, the checks from section 3.8, the table "lib name to intrinsic, runtime call, inline loop or libm", module initialization order and `tsnc_main`, the canonical layout key | AST traversal and SSA construction | `program`, `check`, `bind`, `ast`, `ir`, `abi`, `diag` | Passes |
| `opt` (v2) | IR to IR | `optimize(^Program_IR, level)` | Integer narrowing, escape analysis, bounds check elimination | Analyses | `ir` | Passes in v2; in v1 the package does not exist |
| `target` | Target platform as data | The `Target` enum and a table: LLVM triple, linker, link flags, runtime object name, pointer size | All platform knowledge in one place | Nothing | `base` | Passes: three consumers (`driver`, `codegen`, `link`) |
| `llvm` | Raw LLVM-C 20 bindings | `foreign import` of LLVM-C, names as in C | Declarations | Nothing | none | Passes: adapter package |
| `codegen` | IR to an object file or LLVM IR text | `emit(^Program_IR, Unit, Target, level, artifact kind, path)` returns an error; `init_global_options` is called once before the pool | `LLVMContext`, module, builder, `TargetMachine`, the mapping of IR types and instructions to LLVM, runtime function declarations from the `abi` table, intrinsics, the pass pipeline and `-disable-lsr` | All LLVM handles | `ir`, `abi`, `target`, `llvm` | Passes |
| `link` | Building the executable | `link(objects, Target, output path)` returns an error | The linker and flags from `Target`, finding the runtime object next to the compiler, running the linker (`lld-link` on Windows, the system C compiler on Linux and macOS), capturing stderr | The linker command line | `target`, `core:os` | Passes |
| `driver` | Build orchestration | `build(Options)` returns a report and an error; `check_only` and `run` are stages | The thread pool, arenas per task and per phase, the import graph closure loop (reading files, resolving relative paths, assigning `File_ID` in traversal order), splitting into partitions and units, the "go to `lower` only without errors" policy, temporary files, running the built program for `tsnc run` | How exactly the phases are connected | all packages above | Passes |
| `main` | Command line | `main`: `core:flags` into `Options`, calling `driver`, rendering diagnostics to stderr, exit code | Odin-style flags (requirements, 9) | Nothing | `driver`, `diag`, `source` | Passes |

Embedded lib file: `src/lib/lib.d.ts`. `driver` includes it with `#load`, and it enters `Program` as `File_ID` number zero.

## Package boundaries: runtime

Directory `src/runtime/`, root package `rt` (the name `runtime` is taken by `base:runtime`). It builds separately: `odin build src/runtime -build-mode:obj -o:speed`. The subpackages are plain Odin, tested with `odin test`; `proc "c"` procedures live only in the root.

| Package | Purpose | Entry point | Owns | Hides | Depends on | Deletion test |
| --- | --- | --- | --- | --- | --- | --- |
| `rt` (root) | Entry point and exports | `main` (initializes the heap, reads runtime flags from the environment, calls `tsnc_main`, exits the process); one external `proc "c"` per `abi.Runtime_Proc` under its symbol name from `abi`, each sets up `context` first; `process.argv` built from the executable's path and the arguments, on Windows from UCRT's wide parse | The exports' context: the call's scratch arena as `allocator`, `temp_allocator` reset on exit, `assertion_failure_proc` | Subpackages, the wide command line | all subpackages, `abi`, `core:os`, UCRT on Windows | Passes: shell |
| `gc` | Heap and collector | `heap_init`, cell allocation by type table identifier and size, collection, integrity check | Pages (`mem/virtual`), size classes, the object start map, marking and sweeping, roots: a conservative stack scan after a per-platform assembly stub flushes the registers, and the module globals from the compiler's root table; a precise heap scan via type tables from `abi`; stress mode; under ASan, poisoning of the free heap memory | Heap internals | `abi`, `fail`, `base:sanitizer`, `core:mem/virtual`, `core:strconv` | Passes |
| `fail` | Runtime errors | `fail(code, file, line, column)`: message to stderr, exit code 1 | Message format | Nothing | `core:os` | Passes: called by `gc`, `str`, `arr`, `value` and the exports |
| `num` | Numbers to strings and back | Conversion per `Number::toString`, parsing per the `ToNumber` grammar, `toFixed`; they write into the caller's buffer. `ToIntegerOrInfinity` and the relative index the String and Array methods read a position with | The `1e21` and `1e-7` thresholds, printing `-0` as `0` | `core:strconv/decimal` as the engine underneath | `core:strconv`, `core:strconv/decimal`, `core:math`, `core:unicode/utf8` | Passes: three consumers (`str`, `arr`, `console`) |
| `str` | UTF-16 strings | Creating a cell from UTF-8 and UTF-16, concatenation, slicing, search, splitting, trimming, case conversion by full Unicode rules, comparison by 16-bit units, output in UTF-8 | The string cell in the GC heap, `string16` inside the cell | Case rules and their tables, generated from the Unicode Character Database | `abi`, `gc`, `num`, `fail`, `core:math`, `core:slice`, `core:unicode/utf16`, `core:unicode/utf8` | Passes |
| `value` | Tagged values | `typeof`, strict equality, truthiness, conversion to string by tag | Dispatch by tag | Nothing | `abi`, `gc`, `str` | Passes: three consumers (`arr`, `console`, exports) |
| `arr` | Arrays | Array cell, growth, appending and removing at the end, slicing, search, joining and the string of an array, sorting with a closure comparator per the `abi` convention or in the order of strings, `String.prototype.split` | Buffer, length and capacity | Growth strategy | `abi`, `gc`, `value`, `str`, `num` | Passes |
| `console` | Output | `log`: one statement's arguments formatted as Node's `util.format` and `util.inspect` do (section 3.9), objects and arrays through their type tables, colors as Node decides them, the line written once in UTF-8 | Node's format, the color rules, the column widths of Unicode 17 (a generated table) | Everything but `log`, `format`, `inspect` and the color decision | `abi`, `gc`, `value`, `arr`, `str`, `num`, `fail`, `core:io`, `core:os`, `core:sys/windows` | Passes |
| `table` (v2) | Hash tables in the GC heap | Index signatures, `Map`, `Set`, `Object.keys` | A layout that fits type tables | Hashing (`core:hash`) | `abi`, `gc`, `value`, `str` | v2 |
| `sched` (v2) | `async` and `await` scheduler | Microtask queue, continuations as closures | Execution order | Queue | `abi`, `gc` | v2 |
| `regex`, `bigint`, `fs` (v2) | Regular expressions, `bigint` over `core:math/big`, files and stdin | Per requirements 2.2 and 4.5 | | | | v2 |

What the compiler emits instead of the runtime: `Math` (LLVM intrinsics and libm), `map`, `filter`, `forEach`, `reduce` as inline loops in `lower`, `length`, indexing, arithmetic and comparisons. The rule: whatever holds references to TS values or needs the GC heap goes to the runtime; `lower` emits everything that a loop or an intrinsic can express.

## Package boundaries: tests and tools

| Package | Purpose | Entry point | Depends on |
| --- | --- | --- | --- |
| `tests/runner` (package `main`) | Differential and negative tests | Differential run: `tsc --noEmit --strict` gate, `node` reference, build with `tsnc build`, byte-for-byte comparison of stdout, stderr and exit code, repeat in GC stress mode. Negative run: expected code, line and column from the header comment of the `.ts` file | `core:os` |
| `tests/diff/src/*.ts`, `tests/negative/*.ts`, `tests/diff/package.json` | Corpus | One program per construct from section 2.2 | TypeScript as a dev dependency |
| `bench/` | Benchmarks against Node and Go, results recorded per version | `bench/runner` | `core:os` |
| Unit tests | `tests/<package>/*_test.odin`, one test package per source package (`parse`, `bind`, `check`, `ir` verifier, `num`, `gc`, and others), mirroring `src/`; it imports the tested package by relative path and sees only its public declarations | `odin test tests/<package>` | the tested package |
| CI | GitHub Actions on four images (requirements, 9): smoke, unit tests, differential tests, the same tests in GC stress mode, the runtime with `-sanitize:address` | | |

## Interaction map

All interactions are synchronous calls. Parallelism exists only in the form "`driver` puts a task into the pool and waits for all of them". There are no callbacks between packages and no messages.

| From | To | What is passed | Form | Synchrony | Visible errors |
| --- | --- | --- | --- | --- | --- |
| `main` | `driver` | `Options`: command, input file, output, optimization level, artifact kind, `Target`, thread count | Call | synchronous | Driver error |
| `driver` | `parse` | File text, `File_ID`, task allocator | Call inside a pool task, one per file | fork-join | Diagnostics |
| `driver` | `bind` | `^File_AST`, the same task allocator | Call in the same task right after parsing | fork-join | Diagnostics |
| `driver` | `program` | AST and `Bound_File` arrays by `File_ID`, import edges with paths already resolved | Call | synchronous | The "cycle with side effects" diagnostic |
| `driver` | `check` | `^Program`, partition `[]File_ID`, checker allocator | Call inside a pool task, one per partition | fork-join | Diagnostics |
| `driver` | `lower` | `^Program`, `[]Check_Result`, borrowed for the duration of the call | Call | synchronous | Diagnostics |
| `driver` | `opt` (v2) | `^Program_IR` | Call | synchronous | none |
| `driver` | `codegen` | `^Program_IR`, `Unit`, `Target`, level, artifact kind, path | Call; in v2 a pool task per unit | synchronous; fork-join in v2 | Codegen error |
| `driver` | `link` | Paths of the program and runtime objects, `Target`, output path | Call | synchronous | Link error with the linker's stderr text |
| `driver` | OS | Reading files, temporary files, running the built program | `core:os` | synchronous | Driver error |
| `main` | `diag` | All build diagnostics and the `source` table | Sort and render call | synchronous | none |
| Generated code | `rt` | Arguments per the `abi.Runtime_Proc` signatures | `proc "c"` call | synchronous | A runtime error exits the process with code 1 |
| `rt` (array sort) | Generated code | A closure (code and environment) per the `abi` convention | `proc "c"` call | synchronous | none |
| `rt` | `gc` | Type table identifier and size | Call | synchronous | Out of memory is a failure |

There are no cycles. The only callback, from the runtime into generated code, goes through a procedure type from `abi`, not through an import.

Determinism. `File_ID`s are assigned in breadth-first import traversal order from the input file, with imports in source order, so the numbering does not depend on which task finished first. Partitions are contiguous `File_ID` ranges balanced by size. Diagnostics are sorted by the triple (`File_ID`, offset, code). In v1, `lower` and `codegen` run on one thread in `File_ID` order.

## Contracts

Only what the linked sources do not already cover. In words, without code.

### `Program` (package `program`)

- Purpose: one frozen value that `check` and `lower` read.
- Callers: `driver` builds it, `check` and `lower` read it.
- Input: the `source` table, AST and `Bound_File` by `File_ID`, import edges, `File_ID` of the lib module.
- Output: the same plus the module initialization order and the list of cycles.
- Ownership and lifetime: the parse task arenas and the `program` phase arena; lives until the end of the build.
- Visible errors: the diagnostic "import cycle between modules with top-level side effects".
- Invariants: after the graph is built, the value does not change; `File_ID` number zero is the lib module.
- Abstraction barrier: the caller relies on indexing by `File_ID` and on the initialization order, but not on the sorting algorithm.

### `Check_Result` and `Typed_File` (package `check`)

- Purpose: typing facts for the files of one partition.
- Input: `^Program` and a partition.
- Output: the type table of this call; for each file in the partition, a `Typed_File`: the node type by `Node_ID` (for an identifier this is already the narrowed type at the point of use), the resolved symbol of an identifier (`File_ID` plus an index into `Bound_File`), the chosen call signature, the instantiated generic built-in types. For the whole partition, the widenings: every pair of object types where the rules accepted one where the other was expected, sorted and without repeats, from which `lower` builds one layout per class of types that flow into each other (requirements, 3.3).
- Ownership and lifetime: the checker arena; lives until the end of `lower`.
- Visible errors: diagnostics; nodes that failed to type get the error type in the table.
- Invariants: a `Type_ID` has meaning only together with the table of its `Check_Result`; every file belongs to exactly one partition; with a single partition the result matches any other split.
- Abstraction barrier: `lower` reads a type as a value (kind, fields in canonical order, union members in canonical order, parameters and result); `lower` computes the canonical layout key, and the checker knows nothing about bytes.

### `Program_IR` (package `ir`)

- Purpose: the program with explicit semantics. Every check, tag, reference store and runtime call is an instruction.
- Callers: `lower` builds it; `opt`, `codegen` and the printer read it.
- Ownership and lifetime: the `lower` phase arena. `opt` modifies the value in place, the only phase that mutates its input, because "IR to IR" is its contract. Lives until the end of `codegen`.
- Invariants: SSA; every block ends with a terminator; every instruction has a position; layouts are interned, one structure gives one `Layout_ID`; a reference store into a heap cell goes only through `store_ref`; pointers are not disguised; no pointer arithmetic outside the runtime (requirements, 6).
- Table rows: a layout may have rows that list its fields in another print order, each with the same slots and offsets. Only the header of a cell names a row; every type names the layout. `Program_IR.base` gives, for each row, the layout it reorders.
- Abstraction barrier: `codegen` relies on the closed set of instructions and types; all TS knowledge stays in `lower`.
- Compatibility: v2 adds the `I32` and `I64` types, stack unwinding edges for `try`, and a write barrier as the implementation of `store_ref`. The shape does not change.

### ABI (package `abi`)

- Purpose: everything that generated code and the runtime must understand identically.
- Callers: `ir`, `lower`, `codegen`, `rt` and all its subpackages.
- Contents: the cell header (type table identifier, mark bits); tags and the 16-byte tagged value, with numbers and booleans stored inside without memory allocation; cells for strings (header, length, `u16` data right after), arrays (header, length, capacity, buffer), closures (code, environment), environments (captured slots); the type table: size, the kind of each slot (pointer, tagged, scalar), field names, the array element kind; the `Runtime_Proc` enum with the symbol name and the parameter and result kinds; the closure calling convention (`proc "c"`, environment as the first parameter); the entry point name `tsnc_main`; the name `tsnc_type_tables` of the procedure that hands the runtime the program's type tables at startup; the root table (a slot and its kind for every module global that holds a reference) and the name `tsnc_roots` of the procedure that hands it over; runtime error codes.
- Ownership: in v1 the host equals the target, so `codegen` takes sizes and offsets from `size_of` and `offset_of` of the same structs. In v2, for `wasm32`, a procedure of `Target` computes sizes and offsets, and the runtime checks its structs against it with `#assert`.
- Invariants: the compiler knows the cell layout in full and the runtime knows it in full; a change here is a simultaneous change to both sides, and linking and differential tests catch any mismatch.

### `Diagnostic` (package `diag`)

Value: a code from the enum registry, a span, message arguments. For each code, the registry stores the text and a "how to rewrite" hint. Code numbers are stable and go by range: T1xxx syntax, T2xxx constructs outside the subset, T3xxx types, T4xxx names, modules and imports. Rendering follows the requirements in section 5: the error line, then the hint on an indented line starting with `hint:`. Lines and columns are 1-based, and a column counts UTF-16 code units from the start of the line, as in tsc and VS Code; `source` computes them, and the registry states this rule. Sorting is by the triple (`File_ID`, offset, code). Messages are in English.

### Runtime exports (package `rt`)

Every export is a `proc "c"` under its symbol name from `abi`, kept with `@(require)` and strong linkage rather than `@(export)`, which is dllexport on Windows and would give the executable an export table. It first sets up `context`: the call's scratch arena as `allocator`, `temp_allocator` reset on completion, `assertion_failure_proc` leading to `fail`. Then it calls the subpackage. The GC heap never becomes `context.allocator`. An environment variable turns on GC stress mode and the integrity check; the runtime's `main` reads it once.

## Simplicity and robustness

- Type model: the identifiers `File_ID`, `Node_ID`, `Symbol_ID`, `Type_ID`, `Func_ID`, `Layout_ID` are `distinct` integers. AST nodes and TS types are a `union` with an exhaustive `switch`. IR instructions and types are closed `enum`s and `union`s. `Target`, `Runtime_Proc`, diagnostic codes and runtime error codes are `enum`s with tables indexed by that same enum. No boolean mode flags in contracts: `check_only`, `run` and the artifact kind are separate procedures or an enum.
- Validation boundary: file text becomes an AST in `parse`; foreign entities (LLVM, the linker, the OS) live only in `codegen`, `link`, `driver`; the lib file goes through the same `parse` and `bind` as user files. Pure core: `parse`, `bind`, `program`, `check`, `lower`, `opt`, `ir` and the runtime subpackages except `console` and `fail`. Imperative shell: `driver`, `main`, `codegen`, `link`, `rt`.
- Errors and atomicity: a diagnostic is a value, phases return a partial layer; codegen, link and driver errors are enums of their packages, and `driver` translates them; the build is atomic at the artifact level, output goes to a temporary file that is then renamed.
- Dispatch model: direct calls everywhere. One exhaustive `switch` on the node in `bind`, `check` and `lower`; on the instruction in `codegen`; on the tag in `value`. The only set that looks open, the runtime functions, is closed by the `Runtime_Proc` enum. The only procedure value is the closure calling convention in `abi`, because generated code is a foreign context.
- State model: the build state is a sequence of frozen layers held by `driver`: sources, AST and `Bound_File`, `Program`, `Check_Result`, `Program_IR`, artifacts. Transitions go only forward. The runtime has one piece of state, the heap.
- Memory model: an arena per task and per phase in `driver`, everything lives until the end of the build; phases take `allocator` as the last parameter; temporary data goes through the thread's `context.temp_allocator`. Runtime: the GC heap for TS values, a scratch arena per export call, `core` only for data without references.
- Branching budget: branching sits in `parse` (grammar), `check` (TS rules) and `lower` (semantics in IR terms). `codegen`, `link` and `driver` are linear. The runtime subpackages are straight-line.

## Domain check

DDD relevance: light.

- Ubiquitous language: File, Module (a file as an ESM unit), Node, Symbol, Scope, Type (TS), Layout (IR layout), Cell (GC heap cell), Tag, Tagged value, Closure, Environment, Runtime_Proc, Unit (codegen unit), Target, Diagnostic, Code.
- Bounded contexts: the three type worlds (`check`, `ir`, `codegen`); the runtime as a separate context, with a shared vocabulary only through `abi`.
- Boundaries that keep out foreign concepts: the lib file goes through the normal `parse` and `bind`; LLVM inside `codegen`; the linker inside `link`; the OS inside `driver` and `rt`.

## External boundaries

- LLVM-C 20 (`E:\Odin\dist\LLVM-C.dll` and its Linux and macOS equivalents): only through `llvm` and `codegen`. `codegen` sets the global options (`LLVMParseCommandLineOptions`, `-disable-lsr`), and `driver` calls this once before starting the pool.
- Linker: on Windows the `lld-link` process from the distribution; on Linux and macOS the system C compiler (`cc`), which adds the C runtime startup files, the dynamic loader and the SDK. `target` records which one and its flags, taken from the output of `odin build -print-linker-flags` on each OS without the paths that depend on the machine; `link` finds those paths.
- Runtime object: built separately for each target (`dist/tsnc_rt-<target>.obj`, and `dist/tsnc_rt-<target>-asan.obj` built with `-sanitize:address`, which `tsnc build -sanitize:address` links), `link` looks for it next to the compiler.
- Node and `tsc`: only `tests/runner` through `core:os`, they take no part in the build.
- Generated code and the runtime: through `abi`. The entry point belongs to the runtime: Odin initializes the context, calls `tsnc_main`, and exits the process with the code.

## Provisions for v2

What the v1 architecture already prepares so that v2 features do not break the boundaries.

| v2 feature (requirements, 2.2) | Packages that change | What v1 provides |
| --- | --- | --- |
| Classes, inheritance, `this`, getters and setters | `parse`, `bind`, `check`, `lower` | Object layout by a canonical field table; methods as ordinary functions with `this` as the first parameter; a type table with field names |
| User generics via monomorphization | `check`, `lower` | Instantiation of generic built-in types already in `check`; `lower` interns layouts by structure, and instances go there too |
| `try`, `catch`, `throw` | `ir`, `lower`, `codegen`, `rt/fail` | The failure instruction and a position on every instruction; blocks accept unwind edges without a change of shape |
| `async` and `await` | `lower`, `ir`, `rt/sched` | A closure is a (code, environment) pair with the environment on the heap, so a continuation is a closure |
| Destructuring, spread, optional chaining, `enum`, `export default` | `parse`, `check`, `lower` | Pure sugar over existing IR instructions |
| Index signatures, `Object.keys`, `for...in`, `obj[key]`, `Map` and `Set` | `rt/table`, `lower`, `abi`, `check` | A type table with field names; `Runtime_Proc` grows by rows |
| Full structural typing via fat pointers | `check`, `lower`, `abi` | Direct access when layouts match stays; an IR type "reference with an offset table" is added |
| Integer optimization of `number` | `opt`, `ir`, `codegen` | SSA and explicit instructions; `I32` and `I64` join the closed enum of IR types |
| Escape analysis and bounds check elimination | `opt` | Checks are separate instructions, and the optimization removes them instead of guessing |
| Concurrent GC with write barriers | `gc`, `codegen` | `store_ref` is already a separate instruction: the barrier is its new implementation |
| NaN-boxing, precise roots, shadow stack | `abi`, `lower`, `codegen`, `gc` | All three sides read one tagged value layout from `abi` |
| Hybrid Latin-1 and UTF-16 storage | `abi`, `rt/str` | The string cell is described only in `abi` and `str` |
| N codegen units and ThinLTO | `driver`, `codegen`, `link` | `Unit` in the `codegen` contract from day one; `link` takes a list of objects |
| Cross-compilation and `wasm32-wasi` | `target`, `link`, `rt`, `abi` | `Target` as a table; layout sizes are computed from `Target` |
| Debug info | `codegen` | A position on every IR instruction |
| `RegExp`, `bigint`, file I/O | `rt/regex`, `rt/bigint`, `rt/fs`, lib file, `lower` | New `Runtime_Proc` entries and new declarations in `lib.d.ts` |

## Milestones

Architecture milestones, not tasks. Each one leaves the system working. Order: infrastructure risk first (requirements, 4.2 and 10), then the frontend, then a vertical slice down to an executable, then the full runtime, then parallelism, then v2.

| Milestone | What appears | Packages touched | What is true after |
| --- | --- | --- | --- |
| 1 | A `projects/tsnc` skeleton from `odin-template`; `abi`, `target`, `llvm`, `codegen` without IR (a "hello world" module built by hand), `link`, `rt` with `main`, `console`, `fail`; CI on four images | Infrastructure packages and the runtime shell | The smoke test passes: an executable built through the bindings and the linker prints a line on three OSes |
| 2 | `source`, `diag` with the registry, `ast`, `parse` with the `tokenize` and `parse_tokens` stages, `bind`, unit tests, `main` and `driver` in syntax check mode | Frontend up to `bind` | `tsnc check` finds all syntactic subset violations in one pass; the lib file parses |
| 3 | `program` with the module graph; `check` with a single partition: primitives, literal types, functions and closures, objects under the exact-type rule, arrays, unions and narrowing, generic built-in types, contextual typing, the lib file | `program`, `check`, `driver` | `tsnc check` works fully for the v1 subset; negative tests pass |
| 4 | `ir` with builder, printer and verifier; `lower` for numbers, strings, booleans, functions and control flow; `codegen` from IR; the `-emit-ir` and `-emit-llvm` flags | `ir`, `lower`, `codegen`, `driver` | The first differential tests (numbers, strings, control flow) pass; objects and arrays do not build yet |
| 5 | `gc`, `str`, `num`, `value`, `arr` in the runtime; type tables from `lower`; objects, arrays, closures and unions in `lower`; GC stress mode; runtime build with ASan | The full runtime, `lower`, `abi` | The whole v1 corpus passes differential tests on three OSes in normal and stress mode; the v1 acceptance criterion is met, except parallelism |
| 6 | Thread pool in `driver`: a task per file, N checkers by partition, the `-j:N` flag; a determinism test (`-j:1` and `-j:8` give byte-for-byte identical output) | `driver` | The v1 acceptance criterion (requirements, 10) is fully met |
| 7 | v2 waves per the provisions table, each wave a separate detailed plan: `opt`; classes and generics; `try` and `catch`; `async`; tables; structural typing; codegen units and ThinLTO; cross-compilation and wasm; debug info; regex, bigint, files | Per the provisions table | Each wave adds its own differential tests; package boundaries do not change |

## What must not change and what may

Do not change without asking:

- The eight philosophy rules and the import direction.
- The package list and the single entry point of each package.
- `abi` as the only package shared by the compiler and the runtime.
- The AST is frozen, facts live in tables keyed by `Node_ID`; checkers have private type tables; the layout is a function of structure.
- SSA-IR with explicit checks, `store_ref`, a position on each instruction and `Unit` in the `codegen` contract.
- The embedded lib file in TypeScript.
- Diagnostics as values with a code from the registry; phases do not print.
- The GC heap as the only runtime state; setting up `context` in the exports; `core` only for data without references.

May change during detailed planning:

- Pointers or indices for AST node children (both options satisfy rule 2 if `Node_ID` is dense).
- Tokens as an array or on demand inside `parse`.
- Partition balancing for checkers and the default number of partitions.
- The internals of type interning in `check` and layout interning in `lower`.
- Which built-in methods `lower` expands into a loop and which it hands to the runtime; the boundary from requirements 4.5 still holds.
- Procedure names, file names inside packages, how a package splits into files.
- The format of the `-emit-ir` text dump.

## Assumptions

- (key) The compiler and the runtime are built with the same Odin from `E:\Odin\dist`; the version is pinned together with LLVM 20.
- (key) The runtime imports `src/abi` by relative path; `abi` pulls in nothing but `base`.
- (optional) The runtime object sits in `dist/` next to `tsnc.exe`; a flag can override the path.
- (optional) An environment variable turns on GC stress mode, not a rebuild.
- (optional) The lib file uses `declare` and generic interfaces; `parse` accepts them, `check` rejects them in user files as constructs outside the subset.
- (settled in T5.7) Recursive object types (`interface Node { next: Node | null }`) need no declaration identity: the layout key is shallow, so a string, an object and an array are a reference slot whatever they point at, and a union with an object member is a tagged slot. The key of `Node` is complete before `Node` is.

## Risks and open questions

- Derived pointers from LLVM optimizations under a conservative scan (requirements, 13). Architecturally this is contained in `ir` (`store_ref`, no pointer arithmetic), `codegen` (`-disable-lsr`) and `gc`. The shadow stack fallback touches only `abi`, `codegen` and `gc`. Planning can go ahead.
- Private type tables mean the checkers repeat work on shared dependencies. The cost is accepted, as in tsgo; the compile benchmark in milestone 6 measures it. If it turns out large, a merge step gets added; the decision is marked reversible.
- `string16` from the nightly build is isolated in `rt/str`; falling back to a "pointer plus length" pair does not change `abi` outside the cell.
- Node's format for `console.log` lives only in `rt/console`, ported from `util.inspect` of Node 24 and tested against its output; objects and arrays are proven there and in `tests/link` until milestone 5 lets a program build them.
- The runtime root package is named `rt` instead of `runtime` because of the conflict with `base:runtime`; the directory stays `src/runtime`.

## Handoff to detailed planning

- Next step: the task board `tasks-tsnc.md`. The milestones here group its tasks; the detailed plan (`$direct-plan`) and implementation happen per task, not per milestone, so an agent can take one task per session.
- Implementation: `$direct-writer`. Rules: `$direct-principles`, `$design-language`, `$direct-taste`, `$code-conventions`. Review: `$thermo-nuclear-code-quality-review` and `$code-review-and-quality`.
- A new package, a new mode flag, a new procedure value, new package-level state or an import against the pipeline flow is a sign of a missed decision: stop and come back here instead of adding it silently.
- Do not ask the user about the changeable blocks unless they affect the key ones.
- The document moved to `E:\Odin\projects\tsnc\docs\` together with `REQUIREMENTS.md` and `tasks-tsnc.md` in T1.1.
