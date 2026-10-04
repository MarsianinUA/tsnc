# Task board: tsnc

Source: `architecture-plan-tsnc.md` (section "Milestones") and `REQUIREMENTS.md` v0.1. Updated: October 4, 2026.

Purpose. The operator gives the agent a task number. The agent reads the shared handoff kit and the task kit, makes a detailed plan and writes the code. Tasks do not change the architecture. If a task runs into a key block from the section [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may), the work stops and the question goes back to the operator.

## How to use

Operator prompt template for the agent:

> Do task T2.4 from `docs/tasks-tsnc.md`. First read the shared handoff kit and the task kit. Then run `$casual-plan-2` on the links in the "Where" line; it hands the approved plan to `$direct-writer`. The done criterion is the task's "Done" line. Do not change the key blocks of `architecture-plan-tsnc.md`. If in doubt, stop and ask.

Statuses in the task heading: `[ ]` not started, `[~]` in progress, `[x]` accepted, `[!]` blocked (append the reason to the line). The operator changes the status.

Order. Milestones run strictly in numeric order. Inside a milestone the "After" line sets the dependencies. Different agents can work in parallel on tasks that share no dependencies.

## Shared handoff kit

Every agent reads it before any task.

1. `architecture-plan-tsnc.md`: sections [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), [Key decisions](architecture-plan-tsnc.md#key-decisions), [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may); the rows for your packages in [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler) or [runtime](architecture-plan-tsnc.md#package-boundaries-runtime); your [Contracts](architecture-plan-tsnc.md#contracts).
2. `REQUIREMENTS.md`: §11 (build with `-vet -strict-style`, all repository text in English, repository structure) and the sections from the task's "Where" line.
3. Skills: `$casual-plan-2`, which hands the approved plan to `$direct-writer`. Rules: `$direct-principles`, `$design-language`, `$code-conventions`. Before handing in: `$code-review-and-quality`.
4. Commands: [Commands](development.md#commands) in the development guide. Between edits, `odin check` and `odin test` of the packages you touch; once every edit is in, `tests/all.sh`, which runs what CI runs.
5. General done criterion for any task: `tests/all.sh` is green; no new package, mode flag, package-level state or import against the pipeline beyond the plan; every new diagnostic has a code in the `diag` registry and a hint; all text in English: comments, documentation, compiler messages; the agent makes no commits.
6. The agent's report to the operator at the end: what was done, how it was checked, what is left or what was blocked by the plan.

## Milestone 1: infrastructure and smoke test

Milestone goal: [Milestones](architecture-plan-tsnc.md#milestones), row 1. Requirements §4.2 (first smoke test), §10.

### [x] T1.1 Repository skeleton `projects/tsnc`

What: copy `projects/odin-template`; create `src/`, `src/runtime/`, `src/llvm/`, `src/lib/`, `tests/`, `bench/`, `dist/`; `src/main.odin` parses flags through `core:flags` into an `Options` struct (commands `build`, `run`, `check`; `-out`, `-o`, `-emit-llvm`, `-emit-ir`, `-target`, `-j`) and answers "not implemented" with exit code 1; a README with the commands from the shared handoff kit; move `REQUIREMENTS.md`, `architecture-plan-tsnc.md`, `tasks-tsnc.md` into `docs/`, translated to English.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `main`; requirements §9 (CLI), §11 (repository structure).
After: none.
Done: `odin build src -out:dist/tsnc.exe -vet -strict-style` builds; `tsnc build x.ts` prints the parsed options and exits with code 1.

### [x] T1.2 LLVM-C 20 bindings: `llvm` package

What: generate with odin-c-bindgen or write by hand a subset of LLVM-C 20: Core (context, module, types, builder, constants, functions, attributes, module verifier), Target and TargetMachine, PassBuilder (`LLVMRunPasses`), `LLVMParseCommandLineOptions`, printing a module to text. Names as in C. `foreign import` for `LLVM-C.dll` on Windows; on Linux and macOS the system LLVM 20 provides the library, since the Odin distribution does not ship it there.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `llvm`; [External boundaries](architecture-plan-tsnc.md#external-boundaries); [Precedents](architecture-plan-tsnc.md#precedents), the item on the new pass manager; requirements §4.2, §13 (bindings risk).
After: T1.1.
Done: `odin check src/llvm`; a test creates a context and a module, adds a function, prints the text, frees everything.

### [x] T1.3 `abi` contract, v1 minimum

What: cell header, tags and the tagged value, string, array, closure and environment cells; type table format (size, kind of each slot, field names, array element kind); enum `Runtime_Proc` with a table of symbol names and signatures (in this milestone only string output and failure; the table grows in the runtime tasks); closure procedure type `proc "c"` with the environment as the first parameter; the name `tsnc_main`; runtime error codes; `#assert` on sizes (tagged 16 bytes, reference 8).
Where: [Contracts → ABI](architecture-plan-tsnc.md#abi-package-abi); [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `abi`; [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Compiler and runtime contract"; requirements §3.2-3.6, §4.3, §6.
After: T1.1.
Done: `odin check src/abi`; the package imports only `base`.

### [x] T1.4 `target` package

What: enum `Target` (windows_amd64, linux_amd64, darwin_arm64, darwin_amd64; `wasm32_wasi` is declared but has no table rows), a table: LLVM triple, linker (`lld-link` on Windows, the system C compiler on Linux and macOS), link flags taken from `odin build -print-linker-flags` on each OS, runtime object name, pointer size; parsing of the `-target:` value.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `target`; [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Target platform"; requirements §9.
After: T1.1.
Done: tests for parsing target strings and for a non-empty table for each v1 target.

### [x] T1.5 Runtime shell: `rt`, `console`, `fail`

What: `src/runtime`, package `rt`: `main` initializes the context, calls `tsnc_main`, exits the process; an export that prints a string cell (header followed by `u16` units) as UTF-8 through `core:io` regardless of the code page; `fail`: message to stderr and exit code 1; `context` setup on entry to each export (per-call scratch arena, `temp_allocator` reset, `assertion_failure_proc`).
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), rows `rt`, `console`, `fail`; [Contracts → Runtime exports](architecture-plan-tsnc.md#runtime-exports-package-rt); requirements §3.9, §4.3, §4.5.
After: T1.3.
Done: the runtime object builds on the host; `odin test tests/runtime/console` checks UTF-8 for Cyrillic and emoji.

### [x] T1.6 `codegen`, minimum: hello world module to an object file

What: `init_global_options` (once, `-disable-lsr`); context, module and `TargetMachine` from `Target`; runtime function declarations from the `abi.Runtime_Proc` table; a static string cell in the data section with the `abi` layout; a `tsnc_main` function that calls string output; a pass pipeline by level (`default<O2>`, `default<O3>`, no optimization); output of the object file and the `.ll` text. The entry point already has the form `emit(..., Unit, Target, level, artifact kind, path)`; for now a built-in hello world stands in for the IR.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `codegen`; [Key decisions](architecture-plan-tsnc.md#key-decisions), rows "Codegen unit", "Target platform"; [External boundaries](architecture-plan-tsnc.md#external-boundaries); requirements §4.1 item 5, §4.2.
After: T1.2, T1.3, T1.4.
Done: the package test writes `dist/hello.obj` and `dist/hello.ll`; the module passes the LLVM verifier.

### [x] T1.7 `link` package

What: run the linker that `target` names (the distribution's `bin/lld-link.exe` on Windows, the system C compiler on Linux and macOS) with the flags from `target`; find the library directories the table leaves out because they depend on the machine (Windows SDK and MSVC); inputs: program object, runtime object (found next to `tsnc.exe`, a parameter overrides the path), system libraries; the linker's stderr inside `Link_Error`.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `link`; [External boundaries](architecture-plan-tsnc.md#external-boundaries); requirements §4.1 item 6, §9.
After: T1.4, T1.5, T1.6.
Done: a test links `hello.obj` with the runtime object, runs the result, stdout equals the expected string, exit code 0.

### [x] T1.8 Smoke test: `tests/runner smoke`

What: a `tests/runner` program (package `main`) with a `smoke` mode: `codegen` hello world, `link`, run, compare output. The same program later gets the `negative` (T2.9) and `diff` (T4.7) modes.
Where: [Package boundaries: tests and tools](architecture-plan-tsnc.md#package-boundaries-tests-and-tools); requirements §10 "Infrastructure smoke test".
After: T1.7.
Done: `odin run tests/runner -- smoke` is green on the host.

### [x] T1.9 CI on four images

What: GitHub Actions: `windows-latest`, `ubuntu-latest`, `macos-latest`, `macos-26-intel`; install Odin nightly and LLVM 20 (Linux, macOS); build the compiler and the runtime object; `odin test` of all packages; smoke. T2.9, T4.7 and T5.10 extend the matrix.
Where: [Package boundaries: tests and tools](architecture-plan-tsnc.md#package-boundaries-tests-and-tools), row CI; requirements §9, §10, §13 (macOS only in CI).
After: T1.8.
Done: a green run on all four images.

## Milestone 2: frontend up to `bind`

Milestone goal: [Milestones](architecture-plan-tsnc.md#milestones), row 2.

### [x] T2.1 `source`: file table and positions

What: `File_ID`, `Span` (file, start, end), file table (normalized path, text), conversion of an offset to line and column through a table of line breaks; choose the column unit (code points or UTF-16 units) in the detailed plan and record it in the `diag` registry as a format rule.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `source`; requirements §5 (diagnostic format).
After: T1.1.
Done: position conversion tests on files with `\r\n`, Cyrillic, empty lines.

### [x] T2.2 `diag`: code registry and diagnostic as a value

What: an enum of codes of the form `T0001` with a table of text and hint; `Diagnostic` (code, span, arguments); sorting by (`File_ID`, offset, code); rendering `file:line:col: error[T0123]: text` plus a hint line; the first codes for syntax and the syntactic subset. New codes are added only here.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `diag`; [Contracts → Diagnostic](architecture-plan-tsnc.md#diagnostic-package-diag); [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rules 6 and 8; requirements §2.3, §5.
After: T2.1.
Done: rendering and sorting tests; a test that every code has non-empty text and hint.

### [x] T2.3 `ast`: tree nodes and `Node_ID`

What: node shapes for the v1 subset (§2.2 "v1"), type syntax (union, arrays, object types, function types, literal types, `Array<T>`), `interface` and `type`, ESM import and export, `declare` and generic interfaces for the lib file; `Bad` nodes; dense `Node_ID` within a file; `File_AST` with a list of imports; traversal. Only data and traversal.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `ast`; [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rules 2 and 3; [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Shape of check facts"; [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may), the item on pointers or indices; requirements §4.1 item 2.
After: T2.1.
Done: `odin check src/ast`; a traversal test on a hand-built tree.

### [x] T2.4 `parse.tokenize`: tokenizer

What: TS tokens for v1, number and string literals, template strings with nesting, a "line break before the token" flag for ASI, positions as `Span`; an unknown character or an unclosed literal produces a diagnostic with a code, and parsing continues.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `parse`, stage `tokenize`; [Key decisions](architecture-plan-tsnc.md#key-decisions), the alternative "`lex` as a separate package"; requirements §4.1 item 1.
After: T2.2, T2.3.
Done: tests: operators, numbers (`1e21`, `0x10`, fractional), strings with escapes, nested templates, ASI flags.

### [x] T2.5 `parse.parse_tokens`: recursive descent

What: expressions with precedence, statements, declarations, type syntax, import and export, ASI per the specification; syntactic rules of the subset (`var`, `with`, `namespace`, decorators, `arguments`, `delete`, `eval`, `new Function`) as diagnostics with a hint, recovery through a `Bad` node and continuation; `parse_file` as `tokenize` plus `parse_tokens`.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `parse`; [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rule 8; requirements §2.2 "Never", §2.3, §4.1 item 2.
After: T2.4.
Done: tests for every v1 construct and every syntactic "never" rule (code, line, column); after an error the parser finds the next one.

### [x] T2.6 Lib file `src/lib/lib.d.ts`

What: v1 declarations: `console`, `process` (`argv`, `exit`), `Math`, `Number`, `String` and the string methods from §2.2, `Array<T>` with methods including `map<U>`; only syntax that T2.5 supports; included through `#load`.
Where: [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Built-in types"; [Assumptions](architecture-plan-tsnc.md#assumptions), the item on `declare`; requirements §2.2 (standard library), §4.5 (`Math` bypasses the runtime).
After: T2.5.
Done: a test in `parse` parses the lib file with no diagnostics; the list of declarations matches §2.2.

### [x] T2.7 `bind`: symbols, scopes, flow graph

What: the file's symbol table; scope tree (block-scoped `let` and `const`, functions, parameters); import and export tables by name; control flow graph for narrowing (branches, loops, assignments, in the style of tsc flow nodes); a top-level side effects flag; file-level diagnostics (redeclaration).
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `bind`; [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Name binding"; [Precedents](architecture-plan-tsnc.md#precedents), the item on tsc; requirements §4.1 item 3, §5 (narrowing), §7 (side effects).
After: T2.3.
Done: tests for scopes, closure capture, import and export tables, the flow graph for `if`, `switch` and loops, and the effects flag.

### [x] T2.8 `driver` and `main`: `tsnc check` for syntax

What: reading the input file; the import closure loop (sequential for now): relative paths, `File_ID` in breadth-first order, the lib file as number zero; `parse_file` and `bind_file` per file in a task arena, written as a task procedure (the pool comes in T6.1); collecting diagnostics, sorting and rendering to stderr, exit code.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `driver`, `main`; [Interaction map](architecture-plan-tsnc.md#interaction-map), the "Determinism" paragraph; [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rules 4 and 5; requirements §7, §9.
After: T2.5, T2.6, T2.7.
Done: `tsnc check` on a multi-file example lists all syntax errors in a deterministic order; a missing import file produces a diagnostic at the import position.

### [x] T2.9 `tests/runner negative`

What: the `negative` mode: for each `tests/negative/*.ts`, expectations from header comments (`// expect: T0123 3:5`), run `tsnc check`, compare codes and positions, list the mismatches; first corpus: the syntactic "never" rules; add to CI.
Where: [Package boundaries: tests and tools](architecture-plan-tsnc.md#package-boundaries-tests-and-tools); requirements §10 "Negative tests".
After: T2.8, T1.8.
Done: `odin run tests/runner -- negative` is green in CI.

## Milestone 3: `program` and `check`

Milestone goal: [Milestones](architecture-plan-tsnc.md#milestones), row 3.

### [x] T3.1 `program`: frozen program and module graph

What: `Program` (file table, AST and `Bound_File` by `File_ID`, import edges, the lib `File_ID`); graph construction: topological order through `core:container/topological_sort`, strongly connected components, the diagnostic "cycle between modules with side effects"; `driver` builds `Program` after parsing.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `program`; [Contracts → Program](architecture-plan-tsnc.md#program-package-program); [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Program data umbrella"; requirements §7.
After: T2.8.
Done: tests: chain, diamond, a types-only cycle (allowed), a cycle with effects (error at the import position).

### [x] T3.2 `check`, core: types, table, primitives and functions

What: TS types as a `union` with interning in the checker's table (`Type_ID`); primitives, literal types, `any`, the error type; typing of declarations and expressions (arithmetic, comparisons, logical, bitwise, `typeof`, ternary, template strings); functions and arrows: parameters, return type inferred from the body, functions as values, calls with argument checking; `Typed_File` with tables by `Node_ID`; entry point `check(^Program, partition, allocator)`.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `check`; [Contracts → Check_Result and Typed_File](architecture-plan-tsnc.md#check_result-and-typed_file-package-check); [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Parallel checkers"; [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rule 7; requirements §5, §3.1, §3.7.
After: T3.1.
Done: tests for type inference and mismatch diagnostics; `==` on different types produces an error with a hint about `===`.

### [x] T3.3 `check`: objects, arrays, generics of built-in types

What: object literals and types, `interface` and `type`, optional and `readonly` fields, the exact-type rule with a hint; arrays: `T[]`, literals, element type inference, indexing, methods from lib through instantiation of `Array<T>`; contextual typing of arrow parameters; inferring `U` in `map<U>` from the function body; string methods through lib.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `check`; requirements §3.3, §3.6, §5 (contextual typing, instantiation), §2.2 (methods).
After: T3.2, T2.6.
Done: tests: `Point` and `Vec2` are compatible; `{x, y, z}` into `{x, y}` produces an error with a hint; `arr.map(x => x * 2)` infers `number[]`.

### [x] T3.4 `check`: union and narrowing

What: canonical unions, `T | undefined` for optional ones; narrowing by `typeof`, by a literal field (`===`, `switch`), by `null` and `undefined`, by `!`; uses the flow graph from `bind`; the narrowed type goes into `Typed_File` for the identifier at the point of use; `as` rules (widening and narrowing of a union; `as any` and `as unknown as T` are forbidden).
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `check`; [Contracts → Check_Result and Typed_File](architecture-plan-tsnc.md#check_result-and-typed_file-package-check), invariants; requirements §2.2 (union and narrowing), §3.4, §3.8, §5.
After: T3.2.
Done: tests for each kind of narrowing and for errors outside narrowing; `as any` is rejected with a code.

### [x] T3.5 `check`: modules, lib and semantic rules of the subset

What: resolution of `import` and `export` through `Program` and the `bind` tables, `import * as m`, unknown export; lib module symbols are visible everywhere; `declare` outside lib is rejected; the semantic remainder of the "never" rules (prototypes, `__proto__`, `Symbol`, changing an object's shape); control statements and `for...of` over arrays and strings; `console.log` with any number of arguments; import cycles of only types and functions are allowed.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `check`; [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rule 8; requirements §2.1-2.3, §7, §3.9.
After: T3.3, T3.4.
Done: negative tests for each semantic rule; a multi-file example with a re-export passes.

### [x] T3.6 `driver`: full `tsnc check`, v1 negative test corpus

What: `check` with one partition after `program`; collecting `Check_Result`; the policy "reach `lower` only with no errors"; extend the `tests/negative` corpus to one program for each subset rule and type rule.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `driver`; [Milestones](architecture-plan-tsnc.md#milestones), row 3; requirements §2.3, §10.
After: T3.5, T2.9.
Done: `tsnc check` finds all corpus errors in one pass; `runner negative` is green in CI.

## Milestone 4: vertical slice to an executable

Milestone goal: [Milestones](architecture-plan-tsnc.md#milestones), row 4.

### [x] T4.1 `ir`: data and builder

What: IR types (`Void`, `F64`, `Bool`, `Tagged`, `Ref(Layout)`, `Str`, `Closure`); layouts interned by canonical key (`Layout_ID`); instructions as a closed `union` (arithmetic, comparisons, branches, `phi`, `alloc`, fields, `store_ref`, elements with `bounds_check`, `tag_test`, `box` and `unbox`, `call`, `call_closure`, `call_runtime`, `intrinsic`, `fail`, string constant); `Func` with blocks in flat arrays and `distinct` indices; `Program_IR`; builder; a span on every instruction.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `ir`; [Contracts → Program_IR](architecture-plan-tsnc.md#program_ir-package-ir); [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Shape of our own IR"; requirements §4.1 item 4, §6.
After: T1.3.
Done: `odin check src/ir`; a test builds a function with the builder.

### [x] T4.2 `ir`: printer and verifier

What: a text dump for `-emit-ir` (stable, line-based); verifier: definition before use, a terminator in every block, consistent operand types, `store_ref` only into reference slots.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `ir`; [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may), the item on the dump format; requirements §9 (`-emit-ir`).
After: T4.1.
Done: the verifier catches a block without a terminator and a use before definition; the dump is deterministic.

### [x] T4.3 `lower`: scalar slice

What: `lower(^Program, []Check_Result, allocator)`: numbers, booleans, `null`, `undefined`, string literals as pool constants; functions without captures, and calls; control flow (`if`, `switch`, loops, `break`, `continue`, ternary, `&&`, `||`, `??` through `phi`), `return`; top-level module code as init functions in `Program` order, `tsnc_main`; a "lib name → strategy" table for `console.log` and `console.error`, `process.exit`, `Math` (intrinsics and libm; `round`, `max`, `min` go to the runtime); mapping a TS type to an IR type, without objects. Two leftovers of the milestone 3 review belong here. `Program.init_order` lists a module that is reachable only through `import type`, which Node never loads, so its init function must not run. And every binding slot has to be zero-filled before its scope runs: a `let` with no initializer is written before it is read, but the GC scans it before that, and a hoisted function can read a binding before its declaration ran, which is Node's `ReferenceError` and which check does not catch.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `lower`; [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rule 7; [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Built-in types"; requirements §3.1, §3.5, §4.5 (`Math`), §7.
After: T4.2, T3.6.
Done: the IR dump for programs with loops and `switch` passes the verifier; a test checks that the strategy table covers all names from the lib file.

### [x] T4.4 `codegen` from IR

What: mapping of IR types to LLVM (tagged as a struct of two 64-bit words, references as pointers), instructions one to one, `phi`; runtime function declarations from `abi`; `llvm.*.f64` intrinsics and libm; static string cells; pass pipeline by level; `-disable-lsr`; object and `.ll`; `Unit` as a slice of functions; remove the hello world stub from T1.6.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `codegen`; [Interaction map](architecture-plan-tsnc.md#interaction-map); requirements §4.1 item 5, §4.2, §6 (LSR).
After: T4.3.
Done: a test builds an object for the IR from T4.3; the module passes the LLVM verifier.

### [x] T4.5 `driver`: full pipeline and commands

What: `lower`, `codegen`, `link` in a chain; `tsnc build`, `tsnc run` (runs the program with inherited stdio and passes on its exit code), `-out:`, `-o:none`, `-emit-llvm`, `-emit-ir`, `-target:`; write the artifact to a temporary file and rename it; an arena per phase.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `driver`, `main`; [Simplicity and robustness](architecture-plan-tsnc.md#simplicity-and-robustness), the item on atomicity; requirements §9.
After: T4.4, T1.7.
Done: `tsnc run` on a program of numbers and loops prints the result; `-emit-ir` and `-emit-llvm` write files.

### [x] T4.6 `rt/num` and primitive output in `console`

What: `num`: conversion per `Number::toString` (§3.1) on top of `core:strconv` (shortest representation, thresholds `1e21` and `1e-7`, `-0`, `NaN`, `Infinity`), `parseFloat` per the `ToNumber` grammar, `toFixed`; `console` prints numbers, booleans, `null`, `undefined`, strings, several arguments separated by spaces; `Runtime_Proc` exports; `Math.round`, `Math.max`, `Math.min`.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), rows `num`, `console`; requirements §3.1, §3.9, §4.5 (table, row "Numbers to string and back").
After: T1.5.
Done: `num` tests against a table of values taken from Node (`0.1 + 0.2`, `1e21`, `1e-7`, `-0`, `2 ** 53`); primitive output matches Node byte for byte.

### [x] T4.7 `tests/runner diff` and the first corpus

What: the `diff` mode: gate `tsc --noEmit --strict` (`tests/package.json`, TypeScript as a dev dependency), reference `node test.ts`, `tsnc build`, run, compare stdout, stderr and exit code byte for byte; corpus: arithmetic, comparisons, bitwise, `switch`, loops, functions, template strings, `Math`, `process.exit`; add to CI.
Where: [Package boundaries: tests and tools](architecture-plan-tsnc.md#package-boundaries-tests-and-tools); requirements §10 "Differential tests", "Gate".
After: T4.5, T4.6, T2.9.
Done: the corpus is green on three OSes in CI.

## Milestone 5: full runtime, objects, arrays, closures, union

Milestone goal: [Milestones](architecture-plan-tsnc.md#milestones), row 5.

### [x] T5.1 `gc`: size-class allocator and type tables

What: reserving and committing pages through `core:mem/virtual`; size classes; an object start map (a pointer into a cell finds its owner); allocation with a header by type table ID; registration of the type tables that the compiler places in the object file (a symbol with the table, read at startup); heap integrity check; no collection yet; the only state is `Heap`, initialized in `rt.main`.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `gc`; [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Runtime memory"; requirements §6 (consequences of conservative scanning), §4.5 (row "GC heap pages").
After: T1.5.
Done: tests: allocations of different classes, owner lookup by an interior pointer, integrity check on a live heap.

### [x] T5.2 `gc`: mark-sweep, conservative stack, precise heap

What: an assembly stub per platform (Windows x64, SysV x64, arm64) to spill callee-saved registers and capture the stack bounds; conservative stack scan; precise heap scan by type tables (pointer slots and tagged slots); marking; sweeping into per-class free lists; a trigger threshold; stress mode (a collection on every allocation plus an integrity check) turned on by an environment variable.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `gc`; [Precedents](architecture-plan-tsnc.md#precedents), the item on Go GC, Oilpan, bdwgc; requirements §6, §10 "GC stress mode".
After: T5.1.
Done: tests: an allocation loop with a live set on the stack loses no objects; garbage gets freed; stress mode is green.

### [x] T5.3 `str`: UTF-16 strings and methods

What: string cell in the heap; creation from UTF-8 and UTF-16; `string16` into the cell; `length`, `charCodeAt`, indexing, `slice`, `indexOf`, `includes`, `split`, `trim`, `toUpperCase` and `toLowerCase` by full Unicode rules (`ß` becomes `SS`), `startsWith`, `endsWith`, concatenation, comparison by 16-bit units, `===`; exports in `Runtime_Proc`.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `str`; requirements §3.2, §2.2 (methods), §4.5 (row "Strings"), §13 (`string16` from nightly).
After: T5.1.
Done: tests with Cyrillic and emoji against Node values (`length`, `slice`, `charCodeAt`).

### [x] T5.4 `value`: tagged values

What: `typeof`, strict equality by tag (primitives by value, strings by content, references by address), truthiness, conversion to string by tag; exports.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `value`; requirements §3.4, §3.7.
After: T5.3.
Done: tests for all tags, including `NaN !== NaN` and `-0 === 0`.

### [x] T5.5 `arr`: arrays

What: array cell with a buffer in the heap (unboxed elements by element kind); amortized growth; `push`, `pop`, `slice`, `indexOf`, `includes`, `join`; sorting through `slice.stable_sort_by` over a temporary copy with a closure comparator per the `abi` convention (`undefined` goes last); exports. `sort` is not in `src/lib/lib.d.ts` yet, nor in requirements §2.2, which lets the method list grow: declare it in the lib file here, so that T5.8 can sort with a comparator. `String.prototype.split` gets its export here as well, since it answers a `string[]`: T5.3 left the algorithm in `str` (`splitter`, `split_next`), and the new `String_Split` row passes 4294967295 for a missing limit. Two leftovers of T5.4 belong here. `value.to_string` stops on an array, because an array's string is its elements joined by commas and joining is `arr`'s: convert an array here as `join(",")` (a nested array joins in place, an array that contains itself gives `""`) and send the `Value_To_String` export through it. And `abi.C_Type.Tagged` is a parameter only, so a row whose result is a tagged value, such as `pop` of a `number[]`, needs a shape of its own: Win64 returns a 16-byte struct through a hidden pointer, SysV and arm64 in two registers.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `arr`; [Interaction map](architecture-plan-tsnc.md#interaction-map), row "`rt` (array sort) to generated code"; requirements §3.6, §4.5 (row "Array sorting").
After: T5.4.
Done: tests, including a call to a stub comparator through the calling convention.

### [x] T5.6 Full `console` and `process`

What: Node format for objects and arrays in simple cases (`[ 1, 2, 3 ]`, `{ a: 1, b: 'x' }`) through type tables with field names, nesting; `console.error`; `process.argv` as an array of strings from the OS arguments (UTF-8 to UTF-16); `process.exit`. Two leftovers of the milestone 4 review belong here. A `console.log` of N arguments is 2N unbuffered writes (`src/runtime/console/console.odin`), so a loop that prints is several times slower than Node: buffer one statement without adding runtime state. And `process.argv` must come from `GetCommandLineW` on Windows, because Odin's `os.args` is the ANSI `argv` and turns a non-ASCII argument into code page bytes, which `command_line` in `src/main.odin` already works around for the compiler through `os.current_process_info`. On POSIX the arguments reach `str.from_utf8`, which already decodes as Node's `Buffer.toString` does: one U+FFFD for each maximal broken sequence, and a leading byte order mark kept.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `console`; requirements §3.9, §2.2 (standard library), §13 (Node format risk).
After: T5.5.
Done: output tests against Node values on a set of simple values.

### [x] T5.7 `lower`: objects and arrays

What: canonical layout key from a TS type (fields by name, optional ones as tagged slots, recursive types per the plan's assumption); GC type tables in `Program_IR` (`codegen` emits every layout as a type table since T5.1, so the tables only need interning in `lower`); `alloc` and field access by offset; `store_ref` for reference slots; arrays: literals, indexing with `bounds_check`, a write at `i === length` as `push`, `length`; `map`, `filter`, `forEach`, `reduce` as inlined loops, the rest as runtime calls; `for...of`. Strings too: `length` becomes a load of `String_Cell.length`, and concatenation, templates, comparison, indexing, the other `String` methods, `String(x)`, `toString`, `toFixed` and `parseFloat`, all `Later` in `src/lower/lib.odin` today, become calls to the rows T5.3 added, with the stand-ins those rows name for a missing argument. What T5.5 left for this task: the element of `Array_Push`, `Array_Index_Of` and `Array_Includes` goes in boxed, `Array_Pop` answers through the tagged slot codegen already passes, `join()` passes the `","` constant, `sort()` is `Array_Sort_Default`, and an array literal needs a row that makes an empty array of its layout's table (`arr.new_array` does the work). The runtime finds the table of a `string[]` it builds itself by element kind (`gc.array_table`), so the call that answers one must carry the type `ref(array_layout(.Ref))`. What T5.6 left for this task: the console prints an object's fields in the order `abi.Type_Table.fields` lists them, which must be the order Node enumerates them (integer-like keys ascending, then creation order), while the offsets stay canonical. So an object literal interns a table per literal shape, `{a, b}` and `{b, a}` two tables over one layout, and an optional field is an `ir.Slot` with `optional` set. Add diff programs that print arrays and objects: the console side is done and tested against Node in `tests/runtime/console`, and `process.argv` is a real `string[]` already.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `lower`; [Contracts → Program_IR](architecture-plan-tsnc.md#program_ir-package-ir), invariants; [Assumptions](architecture-plan-tsnc.md#assumptions), the item on recursive types; requirements §3.3, §3.6, §3.8, §4.5 (what the compiler emits).
After: T4.5, T5.5.
Done: diff tests for objects and arrays pass in normal and stress mode.

### [x] T5.8 `lower`: closures

What: a function value as a pair (code, environment); the environment as a heap cell with a type table; captured mutable variables in heap cells, immutable ones by copy; a new `let` binding per iteration; indirect call through `call_closure`; passing closures to the runtime (sorting). What T5.5 left for this task: `Array_Sort` calls the comparator as `code(env, a, b) -> f64`, env first even when it is nil, a boolean as b64 and a tagged value as its two words (`abi.Closure_Cell`), so the closure passed to it needs exactly the `(T, T) => number` shape. `codegen.func_signature` does not follow that convention yet: a function that captures nothing gets no env parameter, a boolean travels as `i1` and a tagged value as one `{i64, i64}` struct. So every function that captures nothing differs too, not only one whose TS parameters differ: either codegen emits a closure body in the `abi` convention or an adapter bridges it. The runtime calls the comparator in another order than V8's TimSort, so no corpus program may print inside one. What T5.6 left for this task: `abi.Closure_Cell.info` points at an `abi.Function_Info` that codegen emits as static data per function: the name as a static string cell (empty for an anonymous function), `length` (the parameters before the first one with a default, or the rest one) and `has_prototype` (true for a declaration or a function expression, false for an arrow). The console prints `[Function: name]` from it, and `%o` its `length`, `name` and `prototype`.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `lower`; requirements §3.5, §6 (closures in the heap).
After: T5.7.
Done: diff tests: counter closures, closures in a loop capture different `i`, sorting with a comparator.

### [x] T5.9 `lower`: union, `any`, optional fields, §3.8 checks

What: the tagged representation; `box` on assignment into a union, `unbox` after narrowing per `Typed_File`; `tag_test` from `typeof` conditions, literal field conditions, `switch`, `null`; `x!` and a narrowing `as` as a tag check with `fail`; `fail` with file, line and column as constants; `undefined` for missing optional fields. What T5.4 left for this task: `typeof`, `===`, truthiness and `String(x)` or a template span of a tagged value call the `Value_*` rows, which take a tagged value as its two words (`abi.C_Type.Tagged`). The runtime refuses a function there, so `String(x)` or a template span whose static type is a function is a compile error. And `value.to_string` is ToString: `"a" + x` with an object operand asks `valueOf` first, so it cannot stand in for `+` on an object that has a `valueOf` field. What T5.6 left for this task: a missing optional field holds a tagged `undefined`, which the console and `%j` leave out as Node leaves out a property that was never set; one set to `undefined` explicitly is left out too, the divergence requirements §3.9 records. What T5.8 left for this task: a closure read out of `any`, `unknown` or a union can be checked by its tag only, never by its signature, so calling one that came that way stays refused; unboxing a function from a union member is fine, since the flows into the union recorded the member's signature class.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `lower`; requirements §3.4, §3.8, §2.2 (union and narrowing).
After: T5.8.
Done: diff tests for discriminated unions and `typeof` branches; a failed `x!` produces the expected stderr and exit code 1.

### [x] T5.10 ASan, stress mode in CI, full v1 corpus

What: a runtime build with `-sanitize:address` for a separate run; `runner diff` in GC stress mode; corpus: one program for each §2.2 v1 construct plus programs with allocations and closures in a loop; a `bench/` starter with hello world (startup time, exe size). One leftover of T5.2 belongs here. ASan's fake stack (`detect_stack_use_after_return`, on by default on Linux since LLVM 15) moves every local whose address is taken off the thread stack, where the collector never looks: the stack base `rt.main` passes lands there, so the scan reads past the real stack, and a live cell kept only in such a local would be freed. The ASan run turns the fake stack off (an `__asan_default_options` that answers `detect_stack_use_after_return=0`) or the scan learns the fake frames. The stress run includes `-o:speed`: it is the only proof of the register spill in `gc.collect`, since a mutation that emptied `spill_registers` passed every `gc` unit test.
Where: [Milestones](architecture-plan-tsnc.md#milestones), row 5; [Package boundaries: tests and tools](architecture-plan-tsnc.md#package-boundaries-tests-and-tools); requirements §10 (v1 acceptance criterion, ASan, stress, benchmarks).
After: T5.9, T5.2.
Done: the whole corpus is green on three OSes in normal, stress and ASan mode.

### [x] T5.11 Tests: delete the unit tests the corpora already cover

What: the first of T5.11 to T5.16, which move behavior tests out of Odin unit tests and into program corpora. A unit test stays only where a program cannot show the behavior (internal tables, hand-built IR, GC internals, a lowering decision) or where an algorithm needs more inputs than a program can hold. `test-corpus-map.md` lists every test with its class and the corpus program that covers it. This task deletes the DUP tests (check 95, lower 58, the other packages 57), the lower DROP tests (24 exact instruction counts that guard no decision), the five lower tests whose failure a `tests/driver/projects` fixture already pins, and the helpers and imports they leave unused: about 4,950 lines. Before a test goes, open the program the map names and confirm it reaches the same construct; when it does not, the test moves to T5.14 or T5.15 instead. Where a deleted diagnostic test also pinned more sites of its error, those sites become `// expect:` lines in the negative program the map names. `check_typed` then runs over fewer inputs, so one new test in `tests/check` runs `check_sources` and `check_typed` over every program of `tests/diff/src`.
Where: `test-corpus-map.md`, sections "Delete: check and lower" and "Delete: the other packages"; requirements §10.
After: T5.10.
Done: every unit test and runner mode is green, under stress and ASan too; a mutation check per deleted group (break the compiler on that path, watch the corpus fail, revert), about ten, listed in the PR description.

### [x] T5.12 `tests/runner expect`: programs with their expected output

What: a runner mode and a corpus `tests/expect/*.ts` for behavior where Node is not the reference by design, which requirements §3.8 keeps out of the differential tests: a failed `x!` or `as`, a read before initialization, `reduce` of an empty array, a string index past the end. The header holds the expectation: one `// stdout: <line>` or `// stderr: <line>` per output line in order, a bare `// stdout:` for an empty line, and exactly one `// exit: <n>`. The runner builds each program by its relative path, so a fail message reads `tests/expect/<name>.ts:L:C` on every OS. It builds at `-o:none` and `-o:speed`, passes `-sanitize:address` on and inherits `TSNC_GC_STRESS`, as `diff` does: the build, run and compare steps of `diff.odin` become one procedure both modes call, with the reference as its input. The tsc gate covers the corpus through the `include` list of `tests/diff/tsconfig.json`, so a program imports nothing. Programs: the eight runs of `expect_failure` in `tests/driver/build_test.odin` with their fixtures (`non-null`, `any-union`, `early-read`), then the failure paths no test runs yet, listed in the map. The replaced tests go: `expect_failure` and its callers, the lower tests the map marks NODE-DIFFERS, the run-time half of the reachability test. CI runs `expect` wherever it runs `diff`.
Where: `test-corpus-map.md`, section "Expected-output corpus"; [Package boundaries: tests and tools](architecture-plan-tsnc.md#package-boundaries-tests-and-tools); requirements §3.8, §10; `development.md` "Differential tests", "CI".
After: T5.11.
Done: the corpus is green in all three CI passes on every OS; one changed word of a message in `src/runtime/fail`, a changed `// exit:` value or a dropped `// stdout:` line fails it; requirements §10, the architecture plan rows for `tests/runner` and the corpus, and `development.md` describe the mode.

### [x] T5.13 `tests/runner negative`: build, files, text; the remaining diagnostics

What: three runner changes. It runs `tsnc build <file> -out:dist/negative-<stem>` instead of `tsnc check`: a build with check errors stops before lower (`build` in `src/driver/build.odin`), so every current program prints what it prints now, and the lower codes T2027 and T2029 become reachable. An expectation may name a file relative to `tests/negative`, `// expect: T4009 modules/relay.ts:1:10`, in print order: the program first, then its modules. And it may end in a quoted text, `// expect: T3001 4:23 "text"`, which must occur in the message or its hint; the text runs to the last `"` of the line. Then the moves the map lists: the check and lower diagnostic tests become `// expect:` lines, one program per code as today, with `type-mismatch.ts` split into three (values and calls, function types, flow); the tests that read a message or a hint, and those with diagnostics in two files, move through the new syntax; T1001 to T1012 get a program per code plus recovery programs, which reverses the earlier choice that the lexer and parser codes stay in `tests/parse` alone (a parse test that also checks the recovered tree or token spans stays); `not-lowered.ts` covers T2027 and `any-to-function.ts` T2029.
Where: `test-corpus-map.md`, section "Negative moves"; requirements §10 "Negative tests"; `tests/runner/negative.odin`.
After: T5.11.
Done: every code of the `diag` registry has a negative program; the moved tests are gone; `development.md` gets the section on the negative corpus it lacks today.

### [x] T5.14 Front end behavior into diff programs

What: the check and lower tests the map marks MOVE-DIFF become programs of `tests/diff/src`: nine new ones (`narrowing-flow`, `literal-narrowing`, `returns`, `definite-assignment`, `union-fields`, `contextual-types`, `structural-types`, `re-exports` with `modules/relay.ts`, `compound-operators`) and extensions of ten existing ones. A corpus program costs about 0.45 s per pass and CI runs ten passes, so a new case goes into an existing program on its topic where one exists. Every program still passes the tsc gate: `import type` for a type, a `.ts` specifier, no comparison of two unrelated literal types. The replaced tests and the helpers they leave unused go.
Where: `test-corpus-map.md`, section "Diff moves: check and lower"; `development.md` "Differential tests".
After: T5.12, T5.13.
Done: the corpus is green in all passes; a mutation check per new program.

### [x] T5.15 Runtime behavior into diff programs

What: the tests of `tests/runtime/{arr,console,str,num,value}`, `tests/codegen`, `tests/parse` and `tests/program` the map marks MOVE-DIFF become programs: extensions of `arrays`, `sort-comparator`, `strings`, `string-methods`, `numbers`, `number-methods`, `format`, `colors`, `math`, `arithmetic` and `any-values`, `array-join` grown out of `join-separator`, and new `sort-default`, `string-case`, `inspect`, `literals`, `module-ring`, `type-import-ring` and `self-import`. A comparator that changes the array does so on its first call only, so the output does not depend on the order V8 calls it in. What no program reaches stays a unit test: the sweeps over every code point and over 300,000 doubles, comparator call counts, invalid UTF-8, color depth per environment, objects with their own `toString`, the string length limit. One stale text goes with it: the risk item of the architecture plan that has `tests/link` prove objects and arrays until milestone 5.
Where: `test-corpus-map.md`, section "Diff moves: runtime and the rest"; [Risks and open questions](architecture-plan-tsnc.md#risks-and-open-questions).
After: T5.11.
Done: the corpus is green in all passes; the replaced tests and the helpers they leave unused are gone.

### [x] T5.16 `lower` tests pin the decision, not the count

What: the lower tests the map marks KEEP-STRATEGY guard a lowering decision no program shows: map, filter, forEach and reduce inlined, a box per pass for a `let` of a `for` header, a union of one representation left untagged, a direct call with no environment, and the rest in the map. Today they assert `len(...) == N` and emission order, so a refactor that keeps the decision still breaks them. Each one gets rewritten to assert the decision itself: no runtime call, one box per pass, a tag test and no call. `lower_helpers.odin` keeps what they use. The `@(private)` above the doc comment of `Local_Place` in `src/lower/expressions.odin` moves between the comment and the declaration. `test-corpus-map.md` is deleted.
Where: `test-corpus-map.md`, section "Lower decisions"; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `lower`.
After: T5.14, T5.15.
Done: a refactor that keeps a decision passes its test and one that changes it fails; the map is gone.

### [x] T5.17 Comments in `src/` say only what the code cannot

What: a pass over `src/` by the comment rule of `$code-conventions` section 10: a comment gives the why, a constraint or a short example, and one that restates the code goes. An audit of 35% of the comment lines found about 12% to remove, some 600 lines. That means restatements, the 63 section dividers such as `// Names.` and the grammar labels of `ast` and `parse` (about 230 lines). It means package headers that retell the architecture plan (about 300 lines: `driver/driver.odin`, `abi/abi.odin`, the thirteen "Memory:" paragraphs), cut to their own facts and a link to the plan section. It means one constraint written in several places, kept in one: the arena that captures the task by pointer (five places), Odin's map iteration order (four), the error type assignable both ways (four). Task numbers such as "from T6.2" give way to the fact they stand for. Why-comments of three to ten lines get cut where one or two carry the reason. Left alone: `src/lib/lib.d.ts`, `src/llvm`, and every comment that records a measured fact or a trap (the `strconv.parse_f64` ulp, `os.same_file` on Windows, the 2^N walk in `check/narrow.odin`).
Where: `$code-conventions` section 10, `$direct-taste` section 3; [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may).
After: T5.10.
Done: the text of `src/` with comments stripped is the same before and after; odinfmt and `odin check` are clean; every test and runner mode is green. T6.1 waits for it, since it rewrites the same `driver` comments.

## Milestone 6: parallelism and determinism

Milestone goal: [Milestones](architecture-plan-tsnc.md#milestones), row 6.

### [x] T6.1 `driver`: thread pool for parsing

What: `core:thread.Pool`; a task per file with its own arena (`pool_add_task` with the task allocator); the import closure loop in waves (all known files in parallel, then the new ones); `File_ID` in breadth-first order regardless of the order in which tasks finish; `-j:N`, defaulting to the number of cores; `codegen.init_global_options` before the pool. Two leftovers of T2.8 belong here. A task arena commits 1 MiB for every file, the default of `core:mem/virtual`, which is 1 GiB for a thousand files: size it by the file instead. And an import whose spelling differs from the file name on disk only by case resolves on Windows and macOS but not on Linux: report it, as tsc does under `forceConsistentCasingInFileNames`, so that a program which passes on one OS passes on all of them.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `driver`; [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rules 4 and 5; [Interaction map](architecture-plan-tsnc.md#interaction-map), the "Determinism" paragraph; requirements §8.
After: T5.16, T5.17.
Done: a test: the same project at `-j:1` and `-j:8` gives the same `File_ID` values and the same diagnostic order.

### [x] T6.2 `driver`: N checkers over partitions

What: split into contiguous `File_ID` ranges balanced by size; a task per partition with arenas; `lower` reads each file's facts from its checker's table; diagnostic sorting; determinism test: byte-identical `-emit-ir`, `-emit-llvm` and executable at `-j:1` and `-j:8`. One leftover of the milestone 3 review belongs here: `context.temp_allocator` is never reset in `check` or in `driver`, and every checker thread needs one of its own.
Where: [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Parallel checkers"; [Contracts → Check_Result and Typed_File](architecture-plan-tsnc.md#check_result-and-typed_file-package-check), invariants; requirements §8, §11.
After: T6.1.
Done: the determinism test runs in CI; the v1 acceptance criterion is fully met.

### [x] T6.3 Benchmarks

What: `bench/`: numeric loops, strings, arrays of objects, closures, allocations against Node and Go; startup time and exe size; compile time at `-j:1` and `-j:N` (the cost of duplicated checker work); results in `bench/RESULTS.md` by version. One idea for the strings benchmark: `str.unit_at` allocates a cell for every `s[i]`, while V8 keeps a cache of single-character strings. Odin cannot build a table of 128 cells at compile time, so 128 spelled-out rows have to pay for themselves in the numbers.
Where: [Risks and open questions](architecture-plan-tsnc.md#risks-and-open-questions), the item on private tables; requirements §10 "Benchmarks", §11.
After: T6.2.
Done: v1 results are recorded.

## After v1: what the benchmarks found

The v1 numbers in `bench/RESULTS.md` show where tsnc lags Node and Go for a reason the compiler or the runtime can remove. T6.4 to T6.6 are what the numbers found. T6.7 and T6.8 were epics E7.1 and E7.11 of milestone 7 and moved here on 2026-09-28, because the same numbers show their gap now: `trees` at twice Node after T6.5, `collatz` and `sieve` at four to five times Go. The tasks change speed, not output: the differential and expected-output corpora are their tests, and `bench/runner` measures each before and after. They run before the v2 waves, in the order below, which is the order of what they are likely to gain.

### [x] T6.4 `s[i]` and string `===` without a runtime call

What: `chars` takes 0.669 s against Node's 0.208. Every `s[i]` is a call to `String_At` (`load_element` in `src/lower/arrays.odin`), every `for...of` step over a string one to `String_Code_Point_At` (`src/lower/statements.odin`), and every string `===` or `!==` one to `String_Equal` (`src/lower/strings.odin`). Each call builds an Odin context and a temp arena guard (`src/runtime/exports.odin`), where V8 does the same work inline. After the bounds check lower already emits, the unit is one load. Candidates the plan picks from: compare against a one-unit string literal as a length and a unit, not a call; answer `s[i]` below U+0080 from the runtime's static table (`src/runtime/str/ascii.odin`), which means an `abi` row for a data symbol generated code may address; put the identity and length tests of `===` in front of the call. Strings stay immutable, and a result may still be a static cell (`src/runtime/str/str.odin`, header).
Where: requirements §3.2, §3.7; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `lower` and `abi`; `bench/ts/chars/main.ts`, `bench/ts/strings/main.ts`.
After: T6.3.
Done: the corpora are green in all passes, under stress and ASan too; a lower test pins each decision the way T5.16 pins them (no runtime call where the plan says none); `chars` runs in at most 1.5 times Node's time.

### [x] T6.5 `T | null` of one reference type as a plain pointer

What: `trees` takes 1.124 s against 0.342 for Node and 0.352 for Go. A union with an object member is a 16-byte tagged slot (requirements §3.4, and the item settled in T5.7 under [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may)), so the node `{left: Tree | null, right: Tree | null}` is a 40-byte cell in the 48-byte size class, against 16 bytes in Go, and the collector marks three times the memory. A union of one reference type (an object, array, string or function type) with exactly one of `null` and `undefined` becomes one pointer slot, 0 meaning that `null` or `undefined`, with its narrowing a compare with 0. Where such a value flows into `any`, a wider union or the console, lower gives it its tag. The layout stays a function of structure. The task amends requirements §3.4 and the T5.7 item, so the operator approves the plan before any code.
Where: requirements §3.3, §3.4, §6; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `lower`, `codegen`, `abi`; the `gc` type table format; `bench/ts/trees/main.ts`.
After: T6.3.
Done: the corpora are green in all passes, under stress and ASan too; a lower test pins that such a slot carries no tag; the node of `trees` is a 24-byte cell; requirements §3.4 and the architecture plan say what changed.

### [x] T6.6 A cheaper entry into the runtime

What: every export starts with `export_context()` (`runtime.default_context()` and two fields, `src/runtime/rt.odin`) and a `DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD`, although most hot exports (`String_Equal`, `String_Char_Code_At`, the `Math` rows, what T6.4 leaves of `String_At`) touch no scratch memory and fail only through an `ensure`. First measure what the two cost per call and what share of `chars`, `strings` and `closures` that is after T6.4. Candidates: a guard only in the exports that use scratch memory; a context built only on the failure path. A third follows the same entry into allocation: every object, array and closure environment is a call to `tsnc_alloc`, which after the entry looks up the type table, checks the trigger, pops the free list of the class, poisons and zeroes, and `trees` makes 29.4 million of them (`bench/bench.sh -gc`). V8 inlines that fast path into generated code and calls the runtime only when a page is full. Here generated code would pop the free list itself, so it reads the heap, and the runtime cannot hand it a data symbol (T6.4). "Setting up `context` in the exports" and "the GC heap as the only runtime state" are key blocks of [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may), so the measurement and the proposal go to the operator before any code.
Where: requirements §4.3, §4.5; [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime); `src/runtime/exports.odin`.
After: T6.4.
Done: the measurement is recorded in the plan; if the operator accepts a change, the corpora are green in all passes, under stress and ASan too, the benchmarks it targets are measured before and after, and the key block's text says what changed.

### [x] T6.7 `opt`: integer narrowing, escape analysis, bounds check elimination

What: Go runs `collatz` in 0.180 s against tsnc's 0.744 and `sieve` in 0.033 against 0.157. Every counter, index and bitwise operand is an f64 converted on each use, a bounds check stands before every element access, and every object, array and closure environment goes to the GC heap (`closures` 0.260 against Node's 0.192: an environment per pass). The package `opt` from [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler) appears: `optimize(^Program_IR, level)`, IR to IR, called by `driver` between `lower` and `codegen`, the only phase that mutates its input. Three passes. Integer narrowing keeps a value the pass proves always an integer in the safe range in `I32` or `I64`, which join the closed set of IR types, and `codegen` maps them; behaviour does not change (requirements §3.1, the Static Hermes precedent). Escape analysis puts an object, array or closure environment that never leaves its function on the stack or splits it into SSA values, so it never reaches the collector (§4.1 item 4). Bounds check elimination removes a `Bounds_Check` the analysis proves, as an instruction, so `codegen` never guesses. This was epic E7.1 of milestone 7. Each pass is a subtask of its own with a corpus program that shows the win; the split goes to the operator first, as the epic's first step would have.
Split (operator, 2026-10-01): T6.7.0 the groundwork (`ir.Flow`, `ir.operands`, the package, the driver call); T6.7.1 the range analysis and narrowing to `I32` and `I64`; T6.7.2 proved bounds checks (`Bounds_Check.proved`); T6.7.3 cells on the stack, which LLVM splits into registers. What stays out: `x = 3x + 1` of `collatz`, which nothing bounds; the per-pass box of a `for` header `let` a closure captures, which reaches the next pass through a phi, so `i % 10` in `closures` stays f64; the checks of `sieve`, whose `j <= LIMIT` tests no length.
Where: requirements §2.2 (the v2 list), §3.1, §4.1 item 4, §13 (the f64 row); [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `ir`, `opt`, `codegen`, `driver`; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), rows "Integer optimization of `number`" and "Escape analysis and bounds check elimination"; `bench/ts/collatz/main.ts`, `bench/ts/sieve/main.ts`, `bench/ts/closures/main.ts`, `bench/ts/objects/main.ts`.
After: T6.6.
Done: the corpora are green at both `-o` levels, in all passes, under stress and ASan too; a test per pass pins its decision on a small IR the way T5.16 pins lower's; `-emit-ir` shows the pass's result; the four benchmarks are measured before and after, and the numbers go to the PR; requirements §3.1 and the plan's row `opt` say the package exists.

### [x] T6.8 Concurrent GC with write barriers; NaN-boxing and precise roots by the numbers

What: `trees` takes 0.75 s after T6.5 against 0.342 for Node and 0.352 for Go. The program builds 24-byte cells in the 32-byte class and drops them, thirty million next to a live tree of 262 thousand, so it measures the allocation path and the collector and nothing else. The v1 collector stops the program, marks the whole live set on every collection, the long-lived tree included, and sweeps every page; a collection comes when the heap has doubled since the last one (`src/runtime/gc/heap.odin`, `GROWTH` and `MIN_TRIGGER`). Requirements §6 name the v2 collector: concurrent tri-colour marking with write barriers in generated code, as in Go. `Field_Store_Ref` and `Element_Store_Ref` are separate IR instructions for this reason: the barrier is their new implementation in `codegen`, and the marker keeps its state inside the heap, which stays the only runtime state. The two other rows of the epic, NaN-boxing (a tagged value in 8 bytes, not 16) and precise roots through a shadow stack in place of the conservative scan (§6, the fallback), were "depending on benchmark results". So far the numbers point at the collector, not at the tagged layout: since T6.5 the hot union of `trees` carries no tag. The task starts with a measurement: how many collections `trees` runs, and how its time splits between the allocation entry (after T6.6), marking and sweeping. `bench/bench.sh -gc` gives the collector's side. On 2026-09-30 it read 109 collections, 0.3 s of marking and 0.09 s of sweeping out of 0.8 s, and 10.6 MB live after the last collection, so marking is where the time goes. Three candidates outside the epic come with it. Generations without moving: mark bits stay set between collections (sticky mark bits), and a minor collection traces only the cells allocated since the last one plus those the write barrier recorded, so the barrier the concurrent marker needs serves twice (Demers et al. 1990 for conservative collectors, sticky Immix in Jikes RVM). §6 lists only concurrent marking for v2, so this one amends it. A 24-byte size class: `CLASS_SIZE` steps by 16 to keep cells 16-byte aligned, so the 24-byte node takes a 32-byte slot and a quarter of what sweep walks is padding. Go has the class; before adding it, check that no cell needs more than 8-byte alignment and how the ASan poisoning of T5.10 treats the slot. The growth policy: the live tree alone puts the trigger at twice 10.6 MB, above `MIN_TRIGGER`, so `GROWTH` decides how many times the same tree is marked; V8 lets its young generation grow to tens of megabytes first. T6.6 left a fourth: allocating inline in generated code, worth at most about 2.4 ns of the 3.4 a cell takes (the plan's risk item on entering the runtime). Then a proposal of which of these to build, in what order, to the operator. This was epic E7.11 of milestone 7. It touches the key blocks "The GC heap as the only runtime state" and "SSA-IR with explicit checks, `store_ref`", and §6's "a v1 program is single-threaded, with one mutator" gains a collector thread, so the measurement and the proposal go to the operator before any code.
Chosen (operator, 2026-10-01): marking takes the reference in a slot as the start of its cell, and only the stack scan looks the owner up; a 24-byte size class, so a cell is 8-byte aligned; the heap grows to four times what a collection leaves, 4 MB at least, where it grew to twice (the 32 MB headroom chosen first made `strings` 24% and `sieve` 11% slower, since the heap left the processor cache); generated code takes a small cell off the free list of its class through `abi.Heap_Head`, which the runtime hands to `tsnc_heap` before `tsnc_main`. What stays out: generations with a write barrier, concurrent marking, NaN-boxing and the shadow stack; the plan's risk item on the cost of the collector gives the numbers.
Where: requirements §6, §4.3, §4.5, §13 (the derived-pointers row); [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), rows `rt` and `gc`; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `ir`, `codegen`, `abi`; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), rows "Concurrent GC with write barriers" and "NaN-boxing, precise roots, shadow stack"; `src/runtime/gc/`, `src/codegen/instructions.odin`; `bench/ts/trees/main.ts`, `bench/ts/objects/main.ts`.
After: T6.6.
Done: the measurement is recorded in the plan's risk item; for what the operator accepts, the corpora are green in all passes, under stress and ASan too, a gc test pins each new invariant the way stress mode pins the v1 ones, `trees` is measured before and after, and requirements §6 and the key blocks' text say what changed.

### [x] T6.9 Recursion depth: the stack size and a message on overflow

What: a program that recurses too deep ends with exit code 127 and nothing on stderr, where Node prints "RangeError: Maximum call stack size exceeded". On Windows a one-parameter function that calls itself once a frame overflowed the main thread's stack past 16 thousand frames at `-o:none` and 21 thousand at `-o:speed` (2026-10-02, i5-13600KF), Node past 15 thousand; a function with more locals overflows sooner. Two parts. The stack size at link time (`/STACK` for lld-link, the `cc` flags elsewhere), chosen for a deep but legitimate recursion. And a failure line through `fail` on overflow, with exit code 1 as for the other errors of requirements 3.8: a handler that runs on a stack of its own, a vectored exception handler for the guard page on Windows and `sigaltstack` with SIGSEGV on POSIX, as Go and Rust do.
Where: requirements §3.8; `src/link`, `src/target`, `src/runtime/rt.odin`, `src/runtime/fail`.
After: none.
Done: an expect program that recurses without end fails with one line on stderr and exit code 1 on every OS, under ASan too; a diff program recurses as deep as Node does.

### [x] T6.10 `check`: a read narrowed through the flow of a module that is not walked yet

What: since the review of T5.11 to T6.8, a loop of declarations is one Tarjan component and a body or an initializer whose type is written out is read once no search is open, so the split of a program into partitions changes no diagnostic of the corpora. One dependence on the order of entry is left, the plan's risk item says. A narrowed read walks the flow of its module back through the statements above it and reads the facts check recorded for them: the type of an assignment, a call that never returns, an exhausted `switch`, the body of an arrow created there. A declaration that another module asks for first is checked before its own module is walked, when those facts may be missing, so its type depends on the split. With `export let mode: string | undefined; mode = "fast"; export const name: string = mode;` in a module the entry imports `name` from, `-j:1` reports T3001 and `-j:8` does not, while tsc accepts it. The fix makes the facts of a module's flow there before any read narrows through them.
Chosen (operator, 2026-10-02): before a read narrowed through the top level of a module, check walks the statements above it that run code and the declarators whose initializer adds to the flow, in order, each statement in a frame of the Tarjan search, so a loop through one is the same component from every entry. Typing only the facts the walk reads, as tsc does, stays out: it needs a walk that can run inside itself and recursion as deep as the chain of statements. After review, a read in a loop through a top-level statement narrows nothing and the walk stops at such a statement, since the facts below it depend on where the loop was entered; and a name a function declares is narrowed inside that function only. The price is a loop tsc does not see where a statement above hands on a function that reads the declaration, which the risk item records.
Where: [Risks and open questions](architecture-plan-tsnc.md#risks-and-open-questions); `src/check/narrow.odin`, `src/check/resolve.odin`; `tests/check/loops_test.odin`.
After: none.
Done: that program types alike under every split in `tests/check/loops_test.odin`, a diff program runs it, and the risk item loses the sentence.

### [x] T6.11 Benchmarks against scriptc and Bun

What: scriptc (Vercel Labs) compiles TypeScript to a native executable through LLVM, as tsnc does, so it is the closest rival, and `bench/` did not measure it. Bun runs the same `.ts` on JavaScriptCore, an engine other than Node's V8. Both run the programs of `bench/ts` as they are, with no twins. They are optional: a missing one, a program scriptc cannot build, or a different output gives a cell of `—` and does not stop the run, while tsnc, Node and Go still must agree. A run past 30 seconds is killed and its cell is `> 30`, since scriptc 0.2.1 never finishes `sieve`. scriptc builds at its default level, `release`, and on Windows links through Zig 0.16. npm puts `.cmd` shims on `PATH`, which `os.process_start` cannot start, so on Windows the runner takes the `.exe` from npm's global root. `-against` leaves both out.
Where: requirements §10 "Benchmarks"; `bench/runner/programs.odin`, `bench/runner/runner.odin`, `bench/runner/tools.odin`; [Benchmarks](development.md#benchmarks).
After: T6.3.
Done: `bench/RESULTS.md` records a run with the five columns.

### [x] T6.12 A large benchmark: a ray tracer over several modules

What: every other program in `bench/ts` is 15 to 60 lines and measures one thing. `raytracer` is a whole program of about 1500 lines over 13 modules. It parses a scene from text with the string methods and a hand-made hash table, builds meshes (an icosphere through an edge table, boxes, a height field from Perlin noise) and a BVH over 3200 shapes, then renders three frames with shadows, reflection and refraction, shapes as a discriminated union and textures as closures. It uses only exactly rounded arithmetic, so tsnc, scriptc, Node, Bun and the Go twin print the same checksum, and it keeps to what scriptc 0.2.1 builds without its embedded engine.
Where: requirements §10 "Benchmarks"; `bench/ts/raytracer/`, `bench/go/raytracer/`.
After: T6.11.
Done: tsnc, Node and Go agree under `bench/bench.sh raytracer`, under ASan too; `bench/RESULTS.md` has its row.

### [x] T6.13 `check`: an array of a narrower element type where a wider one is expected

What: tsnc rejects `Triangle[]` where `(Sphere | Triangle)[]` is expected with T3001, and tsc accepts it. `raytracer` met it passing a mesh's triangles to a function that takes `Solid[]`, so `addAll` in `bench/ts/raytracer/parse.ts` takes `Triangle[]` instead. The element slots differ, a pointer against a tagged 16-byte slot, so the array cannot pass as it is. Objects solve the same problem with flow classes (requirements §3.3): types that flow into each other get one layout. For arrays that would give both the tagged slot wherever such a flow exists, and the array stays one array: a push through either type shows through the other.
Chosen (operator, 2026-10-03): the runtime no longer finds the table of a `string[]` it makes by element kind; lower makes the empty array of the call's type, and `split` and `process.argv` fill it, since a flow of `string[]` into a wider array type tags its slot.
Where: requirements §3.3, §3.4; `src/check`, `src/lower` (the widening classes of T5.7).
After: none.
Done: a diff program passes a `T[]` where `(T | U)[]` is expected, writes through both and prints what Node prints; `addAll` in `bench/ts/raytracer/parse.ts` takes `Solid[]`.

### [x] T6.14 `raytracer` at 1.3 times Node

What: on the first large program tsnc trails Node, 0.611 s against 0.492 and Go's 0.212, while it keeps up with Node on most small ones. The collector is not the cause: `TSNC_GC_STATS` reads 92 collections and 44 ms of marking and sweeping, for 515 MB in 14.6 million cells. The program allocates a `Vec` for every vector operation, a `Hit` for every hit and an array for every BVH walk, calls textures through closures and dispatches shapes by a `switch` over a union. First find where the time goes, with a profiler on the `-o:speed` build or `-emit-ir` of the hot functions (`enters`, `hitTriangle`, `closest`), then bring a proposal to the operator.
Chosen (operator, 2026-10-03): the BVH walk spent about half the time in `push` and `pop` through the runtime and a fifth in `Math.min` and `Math.max` through it, so lower spells push and pop as IR (`Reserve`, `Length`, `Set_Length` and an element access, the runtime growing only a full array), and codegen compares and selects where the operands of min and max differ, with `llvm.minimum` and `llvm.maximum` for equal ones and NaN. The `Vec` and `Hit` temporaries and the `switch` over `kind` stay out; the plan's risk item on entering the runtime gives the numbers.
Where: `bench/ts/raytracer/`; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `lower`, `opt`, `codegen`.
After: T6.12.
Done: the measurement is recorded; for what the operator accepts, the corpora are green and `raytracer` is measured before and after.

## After T6.14: what the design review found

A review on 2026-10-03 asked which decisions of the design, as opposed to single missed cases, keep a compiled program slower than what the compiler knows before run time allows. It measured them with probes, small programs run by tsnc, Node and Bun, and each task below states its finding in words and names the probes. The tasks change speed, not output, so the corpora are their tests; each one measures its probes before and after and puts the numbers in the PR. They are grouped by what they touch: numbers (T6.15 to T6.17), strings (T6.18, T6.19), `opt` (T6.20, T6.21), the layouts `lower` picks (T6.22 to T6.24), then `codegen`, arrays and the collector. T6.15, T6.16 and T6.18 are the cheapest for what they gain. T6.28 closes the review.

### [x] T6.15 `codegen`: a short way from a double to an int32

What: `bsearch` of the review takes 6.9 s against Node's 0.95, and `hash` 4.5 s against 1.2. Every operand of `|`, `&`, `^`, `~` and the shifts that `opt` did not prove an integer goes through `to_int32` (`src/codegen/numbers.odin`), which spells ToInt32 of a double in full: truncate, the remainder by 2^32, two folds, a saturating conversion. V8 and JavaScriptCore convert with one truncating instruction and take the long way only when it overflows: below 2^63 in magnitude, the low 32 bits of the truncation to 64 bits are the answer. Candidates: a compare of the magnitude in front of the code that is there; `llvm.fptosi.sat` to i64 and a test for its two saturated values. NaN and the infinities must still give 0. No program of `bench/ts` does integer work over an array, which is why `bench/RESULTS.md` never showed the gap, so the task adds one, `integers` (the binary search and the hash), with its Go twin.
Where: requirements §3.1; the review's finding that a double became an int32 the long way, probes `bsearch`, `hash`, `mask`; `src/codegen/numbers.odin`; `tests/diff/src/bitwise.ts`; `bench/ts/integers/`.
After: none.
Done: the corpora are green at both `-o` levels, under stress and ASan too; a diff program takes ToInt32 of doubles on both sides of 2^31, 2^32, 2^53 and 2^63, of both signs, of NaN and of the infinities; `hash` and `mask` run in at most 1.5 times Node's time; `bench/RESULTS.md` has the row of `integers`.

### [x] T6.16 `opt`: an upper bound on the length of an array

What: `ranges` caps the length of a string at `abi.MAX_STRING_LENGTH` and leaves the length of an array at 2^53 - 1 (`length_limit` in `src/opt/ranges.odin`), so `length + 1` may leave the safe range and stays a double. Every `push` then converts the length to f64, adds 1 and converts back, and the length is carried through memory from one pass to the next: a copy of `sieve` that only pushes takes more than half of the program's time. In `bsearch`, `hi` comes from `a.length - 1`, so `(lo + hi) >> 1` adds doubles. The task gives an array a largest length the way requirements §3.2 give a string one: an `abi` constant that `ranges` reads and the runtime enforces where an array grows (`reserve` and `new_array` in `src/runtime/arr`), failing with Node's `Invalid array length`. The plan picks the bound: 2^32 - 1 as in ECMAScript, or what a buffer of the widest element can ever take.
Where: requirements §3.1, §3.6, §3.8; the review's finding that nothing bounded the length of an array; `src/opt/ranges.odin`, `src/abi`, `src/runtime/arr`; `bench/ts/sieve/main.ts`.
After: none.
Done: the corpora are green in all passes; an opt test pins that the length a `push` writes is an integer add, and that the sum of two indices stays an integer; an arr test pins the failure at the bound; requirements §3.6 state the bound; `sieve` and `bsearch` are measured before and after.

### [x] T6.17 `opt`: integers through fields, array elements and function values

What: `ranges` knows SSA values, globals, parameters of functions no function value names, and results of direct calls. A number loaded from a field or an element has no range, and neither has a parameter of a function used as a value. So `a[i] & 15` converts a double on every pass (`mask`, 865 ms against Node's 223), `(c.n + c.step) % 8` is a float remainder and a checked conversion to an index (`field-counter`, 1022 against 338), and `(x * 2) % 1000003` in `bench/ts/closures` is an `frem`. The whole-program fixpoint grows by slots: the field of a layout and the element of an array layout hold an integer in range when every store into them does, the runtime's stores included (`split`, `process.argv`, the fill of `New_Array`), and so does a parameter of a function value when every function of its signature class is only called with one. Memory keeps f64, so the runtime and the collector see no change, and a load of such a slot converts once. First measure what T6.15 and T6.16 left of the three probes: a cheap conversion may be enough for `mask`. Whether a proved slot should hold the integer itself, in 4 or 8 bytes, is a question for after the numbers, and it would change `abi`.
Where: requirements §3.1, whose list of what the compiler proves grows by slots; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `opt` and `ir`; the review's finding that a number in memory was never a known integer; `src/opt/ranges.odin`, `src/opt/narrow.odin`.
After: T6.15, T6.16.
Done: the corpora are green at both `-o` levels, under stress and ASan too; an opt test pins each new fact on a small IR, and one pins that a single store of a fraction through any place of the layout takes the fact away; `field-counter` and `mask` are measured before and after; requirements §3.1 name the new facts.

### [x] T6.18 `num` and `str`: an integer to a string, and ASCII case, the short way

What: `to_string` (`src/runtime/num/format.odin`) fills a 384-digit `decimal.Decimal` for every number, an integer too, and `src/runtime/str/number.odin` reads its UTF-8 answer in two passes: `String(i % 1000)` costs about 55 ns against Node's 4 (`num2str`), a fraction about 300 against 60, and that is a quarter of `bench/ts/strings`. `map_case` (`src/runtime/str/case.odin`) decodes code points and reads the Unicode tables twice per character, for ASCII text too: another fifth of `strings`. Candidates: an integer below 2^53 written as digits straight into UTF-16 units; for a fraction, a shortest-digits algorithm in 64-bit and 128-bit integers (Ryu, which Go tries before the `roundShortest` this code follows), with the present path kept where it gives up; a first pass of `map_case` that answers a string with no unit above U+007F in one loop, and the string itself when nothing changes. The digits must stay the ones Node prints: the num tests against Node are the net, and `strconv.parse_f64` stays out of it, being off by an ulp.
Chosen (operator, 2026-10-03): Go 1.27 replaced Ryu with unrounded scaling (`shortFloat` in `src/internal/strconv/uscale.go`), which covers every finite double with no fallback, so `num` ports it with its table of powers of ten and `round_shortest` goes; an integer up to 2^53 skips it, and `toFixed` keeps the exact expansion of `decimal`.
Where: requirements §3.1 (conversion to string), §3.2; [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), rows `num` and `str`; the review's finding that a number became a string through a 384-digit decimal and that case mapping looked every ASCII character up in the Unicode tables, probes `num2str`, `num2str-frac`, `upper`; `bench/ts/strings/main.ts`.
After: none.
Done: the corpora are green in all passes; the num tests that compare with Node cover the new paths at their borders (2^53, the powers of ten, 1e-7 and 1e21); `num2str` runs in at most twice Node's time and `upper` in at most Node's; `strings` is measured before and after.

### [x] T6.19 `str`: one cell for a chain of `+`, and `+=` in a loop in linear time

What: `concat` (`src/runtime/str/str.odin`) copies both sides, and lower emits one call per `+` and per piece of a template (`lower_concat` and `lower_template` in `src/lower/strings.odin`). `a + ":" + b` allocates twice (`concat3`, 230 ms against Node's 93), a template with two numbers makes five cells, and `s += x` in a loop copies the whole string on every pass: 120 thousand appends take 550 ms where Node takes 80 with its start, and the time grows fourfold when the count doubles. Two parts. A chain of `+` or a template becomes one runtime call that sums the lengths, takes one cell and writes the pieces into it, numbers included, with the pieces passed on the stack the way `Console_Log` takes its arguments. And an append in a loop stops copying what is already there. Candidates for the second: a rope, as V8 and JavaScriptCore make, flattened on the first read, which every inline read of a string (`Length`, `Unit_Load`, `===`) would have to know about; or a cell with room to spare that the append fills in place where lower proves the variable holds the only reference to its string (a local no closure captures, appended to in a loop that does not hand it on), which keeps every string flat. Requirements §3.2 call a string a header followed by its units, so a rope amends them and goes to the operator first.
Where: requirements §3.2; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `lower` and `abi`; [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `str`; the review's finding that every `+` on strings copied both sides, probes `append`, `concat3`; `bench/ts/strings/main.ts`.
After: T6.18, whose digits the one call writes straight into its cell.
Done: the corpora are green in all passes, under stress and ASan too; a lower test pins one call for a chain and one for a template; `append` with twice the count takes at most 2.5 times as long; `concat3` runs in at most 1.5 times Node's time; `strings` is measured before and after.

### [x] T6.20 `opt`: small functions inlined before escape analysis

What: `escape` runs per function and before any inlining, so an object a function returns is a heap cell even when the caller reads two fields and drops it. LLVM inlines the callee later but cannot remove the allocation, by then a pop of the heap's free list. `vec` of the review takes 214 ms against 81 for the same arithmetic on variables. Node and Bun have the same gap, so here knowing the program ahead of time can pass them; in `raytracer` the measurement of T6.14 put the `Vec` and `Hit` temporaries at about 5%. The task adds a pass that runs first in `opt`: a direct call to a small function with no loop and no call back to itself is replaced by its body, with fresh values, its `Return`s joined by a phi and its failure sites as they are, so a runtime error names the same line as before. `escape` then sees the cell stay in the caller and puts it on the stack, where LLVM splits it into registers. A cell carried from one pass of a loop to the next, as `acc` in `vec`, still goes to the heap under the rule of requirements §6; the plan weighs splitting a cell whose every use is a field access into SSA values in `opt` itself, which covers that case. The other candidate, a summary "the result is a fresh cell" with the caller lending a stack cell, copies no code but reaches one level only. The plan sets the size limit by the numbers, and measures the compile time with `bench/runner`'s `compile` program.
Chosen (operator, 2026-10-03): the inliner and a pass that splits cells, both before `escape`. A web of cells, `Alloc`s and the phis that join them, is split when each field is written once, where the cell is made and before anything reads it, and the web is otherwise only read through its fields: no compare, box, store or call sees a cell of it, so nothing can tell it from its fields. A callee is inlined at 40 instructions or less, measured: `raytracer` was fastest there, 24, 64 and 100 came within 4%.
Where: requirements §4.1 item 4, §6; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `opt`; the review's finding that a small object a function returned was always a heap cell, probes `vec`, `vec-scalar`; `src/opt/opt.odin`, `src/opt/escape.odin`; `bench/ts/raytracer/vec.ts`.
After: none.
Done: the corpora are green at both `-o` levels, under stress and ASan too, where the heap check for a reference into the stack is the net; an opt test pins the IR of an inlined callee, and one that a function over the limit or one that calls itself stays a call; `-emit-ir` shows the result; `vec`, `raytracer`, `objects` and the compile time are measured before and after.

### [x] T6.21 `opt`: a call through a function value whose function is known

What: a `Call_Closure` stays indirect when the `Make_Closure` or `Func_Ref` it calls is in the same function. `const add = (y) => y + i; made += add(i % 10)` in `bench/ts/closures` makes the closure and calls it through its code pointer in one block, and once T6.20 inlines `apply(times, f, start)`, the call of `f` meets its closure the same way. The pass turns such a call into a direct `Call` with the environment as its first argument, before the inliner looks at it, so the arrow can be inlined and its environment can stay on the stack. `closures` runs in 0.166 s against Bun's 0.134.
Chosen (operator, 2026-10-04): the measurement found that LLVM already calls `add` directly and inlines it, reading the code pointer back out of the closure cell on the stack, and that `apply` keeps its loop, so it is never inlined; two thirds of `closures` was `%`, an `frem` that LLVM makes a call to `fmod`. So the pass is built as written, for what `opt` sees once the call is direct: the body of the arrow, and an environment it can take apart. And codegen takes `%` of two whole doubles below 2^63 in magnitude through `srem`, as V8 does for small integers, leaving `fmod` the rest.
Where: requirements §3.5; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `opt`; the review's finding that a call through a function value stayed indirect with the function in sight; `bench/ts/closures/main.ts`; `src/opt/inline.odin`, `src/codegen/numbers.odin`; `tests/diff/src/arithmetic.ts`.
After: T6.20.
Done: the corpora are green at both `-o` levels, under stress and ASan too; an opt test pins the direct call, and one that a closure which reaches the call through a phi of two functions stays indirect; a diff program takes `%` of whole and fractional doubles around 2^63, of both signs, with zeros, NaN and the infinities; `closures` is measured before and after.

### [x] T6.22 `lower`: a declared function keeps its own signature

What: every declared function takes the signature of its class (`signature_of` in `src/lower/types.odin`), the class is keyed by the IR signature, and a direct call passes the class's positions (requirements §3.5). So one flow changes functions that never meet it: in `fib-callback`, `note(x: number): number` passed as `(x: number) => void` makes `fib`, which no function value names, return a tagged value, 412 to 435 ms. A tagged parameter or result also has no range, so `opt` loses the integers behind it. The other way round: a function keeps the signature it declares and direct calls use it; where the class's signature differs, the function value carries the code of an adapter with the class's signature, which converts the arguments, calls the function and converts the result, as the sort adapter does for a comparator. One adapter per function, so the value is still one cell and `===` holds, and a call through a function value pays one more jump only for a function that differs from its class. The task amends requirements §3.5, so the operator approves the plan before any code.
Chosen (operator, 2026-10-04): only a `function` declaration with no environment keeps its own signature, since it is the one function a call names directly. An arrow, or a declaration that captures, is called only through its value, so it keeps its class's signature and needs no adapter: an own signature would only add a jump to every call of it, recursive ones too. The adapter is made the first time the function's value is, and named `<function>.adapter`, which no identifier can spell. A void declaration returns a tagged value only where it may hand on what a call answered, which `hands_on_value` judges by the class of the callee even for a direct call: a safe excess, never a lost value.
Where: requirements §3.5, §3.8; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `lower` and `codegen`; the review's finding that a function's signature followed its class, in direct calls too, probes `fib`, `fib-callback`; `src/lower/types.odin`, `src/lower/calls.odin`, `src/lower/lower.odin`, `src/lower/closures.odin`; `tests/diff/src/function-types.ts`.
After: none.
Done: the corpora are green in all passes, under stress and ASan too; a lower test pins that `fib` of the probe keeps its f64 result and that `note` has an adapter; `fib-callback` runs in `fib`'s time; requirements §3.5 say what changed.

### [x] T6.23 `lower`: a union of reference types as one pointer

What: a union of two or more object types is a 16-byte tagged value (`representation` in `src/lower/types.odin`, requirements §3.4), although the header of every cell names its layout. Reading a field of a member repeats a tag test, an unbox and a layout test (`union_field_place` in `src/lower/unions.odin`); an element of a `Solid[]` in `raytracer` is 16 bytes; a literal passed to a parameter of the union type is boxed, and a boxed cell goes to the heap (§6) where the same literal passed as its own type stays on the stack. T6.5 made the union of one reference type with `null` or `undefined` a pointer. The same holds for several reference types: a string, a function, each array layout and each object layout have a table id of their own, so the header answers what `typeof`, a layout test and a narrowing on a literal field ask, and 0 still stands for the one `null` or `undefined`. By itself the gain is small: `shapes` is 2.4 times ahead of Node already, and T6.14 measured the `switch` over `kind` under 3% of `raytracer`. So the task starts with a measurement, by a prototype if nothing shorter shows it. It is the representation T6.24 builds on. The task amends requirements §3.4, so the operator approves the plan before any code.
Chosen (operator, 2026-10-04): a union of several object and array types, with at most one of `null` and `undefined`, is one pointer; a union that also holds a string or a function stays tagged, since its tag, `===` and truthiness would have to come from the header. The measurement first, with today's compiler: `shapes` took 175 ms, and the same work on one interface with every field, so no tag and no layout test, 113; a literal passed to a parameter of the union took 155 ms, boxed onto the heap, and passed to its own type 71. After the change `shapes` takes 147 ms, the literal stays on the stack and takes 72, and `raytracer` (0.231 s), `sieve` and `objects` are the same within noise; an element of `Solid[]` is 8 bytes. A slot of several layouts is a slot kind of its own (`Any_Ref`), since the shallow key must tell `{p: Circle}` from `{p: Circle | Rect}` for a read through the narrower type to test the layout. Teaching `split` to fold the layout test of a cell it knows was left out: LLVM already takes the stack cell of the literal apart.
Where: requirements §3.4, §3.8, §6; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `lower`, `ir`, `codegen`, `abi`; the `gc` type table format; the review's finding that a union of object types was a tagged value, probe `shapes`; `src/lower/types.odin` (`nullable_reference` of T6.5), `src/lower/unions.odin`; `bench/ts/raytracer/shapes.ts`.
After: none.
Done: the measurement is recorded; if the operator accepts the change, the corpora are green in all passes, under stress and ASan too, a lower test pins that such a union carries no tag and that a literal passed to it can stay on the stack, an element of a `Solid[]` is 8 bytes, `shapes` and `raytracer` are measured before and after, and requirements §3.4 say what changed.

### [x] T6.24 `lower`: widening that the wide side pays for

What: types that flow into each other share one layout for the whole program, and a slot whose types differ is tagged (requirements §3.3, §3.6; `build_classes` in `src/lower/types.odin`). So one line changes every value of that shape. A flow of any `number[]` into an array of numbers or strings tags every `number[]`: `sum-widened` takes 358 ms against 210 for `sum` and falls behind Node. A few lines that pass a `Vec`-shaped object where its `x` may be a string too slow `raytracer` from 311 to 368 ms. And the class key is shallow, so `Label {pos: string}` passed where `pos` may be a number tags `Body {pos: Vec}`, which it never meets. Node and Bun decide per array and per hidden class at run time, when a wider value is stored; scriptc copies the array, which breaks aliasing. The direction: a value keeps the layout it was made with, a place of the wide type holds one of several layouts told apart by the header (T6.23), and a read through it dispatches and boxes what it loads, so the narrow code pays nothing. What is left is a write through the wide type of a value the narrow slot cannot hold. Candidates: join the classes as today, but only where such a write can reach a narrow value, which needs a flow analysis and changes no behaviour; fail at that write, as Java and C# do for a store into a covariant array, which moves the error of requirements §3.8 from a later read to the write and so rejects programs Node runs; for arrays only, move that one array to the tagged layout at the write, as V8 does, with a test of the header before a loop over the narrow type. A deeper class key, which tells a string slot from an object slot, removes the `Label` and `Body` case alone and is a step of its own. The layout stays a function of structure. The task amends requirements §3.3, §3.6 and maybe §3.8, so the candidates, with a prototype's numbers, go to the operator before any code.
Chosen (operator, 2026-10-04): join the classes as today only where a write can reach a narrow value. A write is an assignment to a field or an element, `++` and `--` of one, `push`, `pop` and `sort`, and an `as` to a narrower type, which check now records beside the widenings; it also reaches every object and array type the value it stores may hold, since that cell lands where a narrower type of the field reads it. A type no write reaches, which other types flow into, is a view: its places hold any of their layouts, and a read through it tests the layout, as a union of objects does since T6.23, and boxes what that layout holds. The key of a class also tells a slot that holds a string from one that holds a function or an object, which a read through a view needs to know what to box; where two layouts of a view differ only in that, the header cannot tell them apart, and they share a layout as before. The numbers with today's compiler, before and after: `sum` 199 ms, `sum-widened` 334 and 200, `raytracer` 233, `raytracer-widened` 271 and 233; the IR of every program of `bench/ts` is the same as before.
Where: requirements §3.3, §3.6, §3.8; [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may); [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `check`, `lower`, `ir`; the review's finding that a widening flow changed every value of that shape, probes `sum`, `sum-widened`, `raytracer-widened`, `strangers`; `src/lower/types.odin`, `src/lower/expressions.odin` (`coerce`); `tests/diff/src/widening.ts`.
After: T6.23.
Done: the proposal is recorded; for what the operator accepts, the corpora are green in all passes, under stress and ASan too, `tests/diff/src/widening.ts` still prints what Node prints, a lower test pins that `sum` of `sum-widened` reads f64 elements and that `Body` of `strangers` holds a pointer, `sum-widened` runs in `sum`'s time and `raytracer-widened` in `raytracer`'s, and the requirements say what changed.

### [x] T6.25 `codegen`: what LLVM may assume about memory and the runtime

What: every field and element access is a GEP over `i8` with no alias metadata, and `declare_runtime` (`src/codegen/module.odin`) gives a runtime function no attribute but `noreturn`. So LLVM assumes that a store of an element may change the array's length and its elements pointer, and loads both again after each one (the inner loop of `sieve`; `a[i] = a[i] * k` does not vectorize). A call into the runtime, a cold one too, may change every global, so `text` in `bench/ts/chars` is loaded on every pass. Two parts. Type-based alias metadata, a tag per kind of place (the cell header, an array's length, its elements pointer, an f64 element, a reference element, a field of a layout), since places of different kinds never overlap. And an effect per row of `abi.Runtime_Export` (reads only, allocates, may call back into the program) that `declare_runtime` turns into LLVM attributes, with `nounwind` on every row. What this gains is not measured, so the task starts with a prototype on `sieve`, `chars` and `raytracer`. A tag or an effect stated wrong is a miscompile the corpora may not show: `Reserve` writes the elements pointer, a collection reads every cell, and the conservative scan needs the base pointer of a cell alive across a call (requirements §6).
Measured (2026-10-04), the median of 11 runs before and after: `sieve` 86 and 87 ms, `chars` 133 and 125, `raytracer` 218 and 203; `a[i] = a[i] * k` over a million elements, 200 times, now vectorizes and takes 72 ms against 106. The inner loop of `sieve` no longer loads the length and the elements pointer, but it waits on memory. Most of the rest comes from the call tag: without it `chars` took 135 ms and `raytracer` 215, since a call of an Allocates export, the slow path of an inline allocation among them, no longer makes LLVM load fields and globals again. Without the attributes `chars` took 127 and `raytracer` 210, inside the noise but both the same way. The tags and the effects are described in requirements §6 and in `src/codegen/alias.odin`.
Where: requirements §4.2, §6, §13; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `codegen` and `abi`; the review's finding that LLVM was told nothing about memory; `src/codegen/instructions.odin`, `src/codegen/module.odin`, `src/abi/calls.odin`.
After: none.
Done: the measurement is recorded; if it pays, the corpora are green at both `-o` levels, under stress and ASan too, a codegen test pins the metadata of each kind of access and the attributes of one export per effect, and the three benchmarks are measured before and after.

### [x] T6.26 `arr`: one byte for an element of `boolean[]`

What: `abi.SLOT_SIZE` gives a boolean 8 bytes, in an array's buffer too. The 2 million flags of `sieve` are 16 MB a round against 2 MB in Go, past the processor's cache: the same pushes and marks on arrays of 250 thousand run 30% faster (`sieve-small`, 94 ms against 134). The task gives the element of a `boolean[]` one byte: the element size comes from the array's table, `codegen` scales the index by it, and the runtime's `store`, `load`, `sort` and `join` and the console read a byte. A field of an object stays 8 bytes, since alignment would take the gain back, and an array a widening flow tags keeps its 16-byte slot.
Measured (2026-10-04), the median of 11 runs before and after: `sieve` 84 and 32 ms, as fast as Go (32); `sieve-small` 65 and 54 ms, launch included.
Where: requirements §3.6; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `abi`, `lower`, `codegen`; [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), rows `arr` and `gc`; the review's finding that an element of `boolean[]` took 8 bytes, probe `sieve-small`; `bench/ts/sieve/main.ts`.
After: none.
Done: the corpora are green in all passes, under stress and ASan too; an arr test pins the size of the element; `sieve` is measured before and after.

### [x] T6.27 `gc`: a collection that does not pay again for what lives on

What: a collection marks every live cell and sweeps every page: `sweep_page` (`src/runtime/gc/collect.odin`) reads every slot and writes each dead or free one into a free list again. `trees` spends 125 of its 349 ms in the collector; without its long-lived tree the program takes 239 ms, 41 of them in the collector, so about a third of the run pays for cells that never die, and Bun runs `trees` in 293 ms. T6.8 weighed generations with a write barrier and left them out; this number is new. Candidates: sticky mark bits, where a minor collection traces only the cells allocated since the last one and what a barrier in `Field_Store_Ref` and `Element_Store_Ref` recorded, as JavaScriptCore's collector does, which also never moves a cell and scans the stack conservatively; sweeping a page when allocation reaches it, not all pages at once; mark bits beside the page, so that sweeping writes no free list, as in Go. Every store of a reference pays for the barrier, so the task starts with what it costs on `objects` and `raytracer` and brings the numbers and a proposal to the operator. It touches requirements §6 and the key block "The GC heap as the only runtime state".
Chosen (operator, 2026-10-04): generations on sticky marks, after the cost of the barrier. A cell a collection kept stays marked and is old. A minor collection marks from the stack, the roots and the old cells the barrier remembered, which wait on the mark stack, and its sweep skips each page the last sweep left full; a full collection takes the marks off first and comes once minor ones kept more than the last full one left, and more than 4 MB. Codegen tests the header after `Field_Store_Ref` and `Element_Store_Ref` and calls `tsnc_remember` on the rare path, except for a cell on the stack, a cell made with no collection since and a constant; lower evaluates the fields of a literal before it allocates the cell, so their stores need none; `arr` runs `gc.write_barrier` after each store of its own.
Measured (2026-10-04), the old and the new build in turn, the median of 21: the barrier alone cost `objects` 4.5% and `raytracer` 3.5%, and nothing and 2 to 3% with those exceptions. With the collector `trees` takes 267 ms in place of 372, 3 of its 48 collections full, `objects` 234 in place of 245, `closures` 172 in place of 167 with the same loops and collections, the other programs the same within the noise, `trees-short` too. The heap peaks higher: `trees` 45 MB in place of 42, `objects` 67 in place of 59.
Where: requirements §6; [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `gc`; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `codegen`; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), row "Concurrent GC with write barriers"; [Risks and open questions](architecture-plan-tsnc.md#risks-and-open-questions), the item on the cost of the collector; the review's finding that every collection paid for everything alive, probe `trees-short`; `src/runtime/gc/`.
After: none.
Done: the measurement is recorded in the plan's risk item; for what the operator accepts, the corpora are green in all passes, under stress and ASan too, a gc test pins each new invariant, `trees`, `objects` and `raytracer` are measured before and after, and requirements §6 say what changed.

### [x] T6.28 Close the performance review

What: once the operator has accepted or dropped each of T6.15 to T6.27, run every probe of `docs/performance-review.md` and `bench/bench.sh` again and compare with the table there. `bench/RESULTS.md` gets a section with the numbers after the review. What the tasks left open, and what still holds of the file's "Seen and left out", moves in a sentence each to [Risks and open questions](architecture-plan-tsnc.md#risks-and-open-questions) or to the row of its epic in milestone 7. Then `docs/performance-review.md` is deleted, and with it the links to it: the "Where" lines of T6.15 to T6.27 and the opening paragraph of this section name the finding in words instead.
Where: `docs/performance-review.md`; `bench/RESULTS.md`; [Risks and open questions](architecture-plan-tsnc.md#risks-and-open-questions).
After: T6.15 to T6.27.
Done: the file is gone and nothing in the repository links to it; `bench/RESULTS.md` has the section; the plan holds what stayed open.

## Milestone 7: v2

Milestone goal: [Milestones](architecture-plan-tsnc.md#milestones), row 7; requirements §2.2, the v2 list. The tasks below were written on 2026-10-04 from the [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2) table and the code at 03f56f3, in place of epics E7.2 to E7.12; E7.1 and E7.11 had become T6.7 and T6.8. The operator added three constructs §2.2 does not list: tuples, which type `for (const [k, v] of map)` and `Object.entries`, default parameter values and `interface extends`. T7.1 comes first, since its numbers may move a task to another wave or add a construct. A task whose design is still open starts with a prototype or a measurement and brings its candidates to the operator before any code, as T6.23 to T6.27 did, and the operator's answer becomes its "Chosen" line. Every feature adds its diff programs (requirements §10). A construct a task supports stops reporting its T2xxx code: the code is retired and its number is not reused, its negative program goes, and each new code gets a negative program of its own. What the performance review left open stays in [Risks and open questions](architecture-plan-tsnc.md#risks-and-open-questions) until a task here needs it.

## v2 wave 0: what real programs need

Requirements §10 ask for real programs run through `tsnc check` once per version, and §13 for the rejection rate of the exact-type rule before v2. Nothing in `tests/` or `bench/` does either yet.

### [ ] T7.1 What the subset rejects in real programs

What: pick five to ten small real TypeScript programs with no npm dependencies and no DOM: command-line tools, algorithms, game logic. The plan decides whether they are copied into the repository under a license that allows it, or named by URL and commit and kept outside. Run `tsnc check` on each and count the diagnostics by code, the T2021 ones by their `Construct` (`src/diag/codes.odin`), and those that come from the exact-type rule (`object_assignable` in `src/check/types.odin`, and T3011 for an extra field of a literal). The counts say which waves matter most, whether structural typing (T7.25) should come earlier, and which of the T2021 constructs left outside v2 (intersection types, labels, function overloads, `as const`, `satisfies`, `export *`) earn a task.
Where: requirements §10 "Checks on third-party code", §13 (the row on the exact-type rule), §2.3; `src/diag/codes.odin`.
After: none.
Done: a report in `docs/` gives each program's size and its diagnostics by code; the operator confirms or reorders the waves of this milestone and names the constructs that join v2.

## v2 wave 1: syntax over the IR that exists

The [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2) row "Destructuring, spread, optional chaining, `enum`, `export default`" calls these pure sugar over existing IR instructions: they change `parse`, `bind`, `check` and `lower`, and none needs the runtime. The tuples, default values and `interface extends` the operator added belong here too.

### [ ] T7.2 `interface extends` and default parameter values

What: both are T2021 today, `Interface_Extends_Clauses` (`src/parse/statements.odin:334`) and `Default_Parameter_Values`. `interface B extends A, C` gives B the members of its bases, generic bases instantiated, and a member B declares again must fit the base's, as tsc requires; the layout stays a function of the fields. A parameter with a default is optional to the caller, and the callee evaluates the default when the argument is `undefined`, an explicit `undefined` too, in parameter order, so a default may read the parameters before it. Inside the function the parameter has its declared type; where a function with defaults flows into a function type, the signature class carries `T | undefined` in that position.
Where: requirements §2.2, §3.5; `src/parse/statements.odin`, `src/parse/types.odin`, `src/check/objects.odin` (`read_interface`), `src/check/resolve.odin`, `src/lower/bindings.odin`.
After: none.
Done: diff programs extend interfaces in a chain and from two bases, and call functions and arrows with defaults omitted, passed and passed as `undefined`; requirements §2.2 list both constructs; their two T2021 rows are retired.

### [ ] T7.3 Optional chaining `?.`

What: the parser builds a chain of `Member` nodes and then discards it (`src/parse/expressions.odin`), reporting T2016 once per chain (`src/parse/expressions.odin:452`). `a?.b`, `a?.[i]`, `f?.()` and `o.m?.()`, where a `null` or `undefined` link skips the rest of the chain, side effects included, and gives `undefined`. The result has type `T | undefined`, a pointer of kind `Ref_Or_Undefined` where `T` is a reference (T6.5). As in tsc, `if (a?.b)` and `a?.kind === "x"` narrow `a` to non-null.
Where: requirements §2.2, §3.4; `src/ast`, `src/parse/expressions.odin`, `src/check/narrow.odin`, `src/lower/unions.odin`.
After: none.
Done: a diff program puts `null` and `undefined` at each link of member, element and call chains, shows the side effects that are skipped and the narrowing through `?.`; T2016 is retired.

### [ ] T7.4 Tuples

What: T2021 `Tuple_Types` today. A fixed tuple type `[A, B]`, an array literal typed by it from its context, an index that is a literal typed by its position, a `.length` of a literal type, and a tuple passed where an array of a wider element is expected, as tsc allows. The representation goes to the operator before any code: an `Array` cell with a tagged slot where the element types differ, which the console, `for...of`, the Array methods and the widening classes of T6.13 and T6.24 already handle; or an object layout with the fields `0`, `1`, which reads an element with one load and no tag, but needs a case in every path that takes an array. Optional and rest elements stay out unless T7.1 asks for them. The task amends requirements §2.2 and §3.6.
Where: requirements §2.2, §3.6; `src/parse/types.odin`, `src/check/types.odin`, `src/lower/types.odin` (`representation`), `src/lower/classes.odin`.
After: none.
Done: a diff program makes, indexes, passes, prints and iterates tuples of mixed types and passes one where an array is expected; requirements §2.2 and §3.6 say what a tuple is.

### [ ] T7.5 Destructuring

What: T2014 today (`src/parse/statements.odin:240`, `src/parse/expressions.odin:62` and :816); `parse_binding_name` skips a pattern and leaves the name empty, and `bind` declares one symbol per declarator. Object and array patterns in `const` and `let`, in parameters, in a `for...of` head and on the left of an assignment, with nesting, renaming (`{x: y}`), defaults by the rule of T7.2, and rest: `[a, ...r]` takes a slice, `{a, ...r}` a new object of the remaining fields, whose layout those fields give. An array pattern longer than the array reads out of range, which is the error of requirements §3.8 for `arr[i]`, where Node gives `undefined`.
Where: requirements §2.2, §3.8; `src/parse`, `src/bind`, `src/check`, `src/lower/bindings.odin`.
After: T7.2, T7.4.
Done: diff programs destructure objects, arrays and tuples in each of the four places, with nesting, renaming, defaults and rest; an expect program pins the pattern longer than its array; T2014 is retired.

### [ ] T7.6 Spread and rest parameters

What: spread is T2015 today (`src/parse/expressions.odin:551` for arrays and calls, :768 for objects). Rest parameters of user functions pass `check` and stop in `lower` with T2027 (`src/lower/lower.odin:259`), while the lib uses them (`console.log`, `push`, `Math.max`). An array literal with spread `[...a, x, ...b]` makes one array, sized once where the lengths are known; a spread argument goes into a rest parameter, or fills fixed parameters from a tuple; a rest parameter of a declaration, an arrow or a function value gets a fresh array on every call, as in Node; an object spread `{...a, b: 1}` makes a new object whose fields are those of both sides, the later one winning, under the exact-type rule; a string spreads by code points, as `for...of` walks it. Spread into `Math.max` and `console.log` goes through the `Rest` C type of `abi`.
Where: requirements §2.2, §3.5, §3.6; `src/parse/expressions.odin`, `src/lower/calls.odin`, `src/lower/arrays.odin`.
After: T7.4.
Done: diff programs spread arrays, strings and objects, call with spread arguments, and declare rest parameters on declarations, arrows and function values; T2015 and the rest-parameter case of T2027 are retired.

### [ ] T7.7 `enum`

What: T2013 today (`src/parse/statements.odin:641`). Numeric enums with auto-increment and constant initializers, string enums, `const enum`; an enum as a type (the union of its members) and as a value (`E.A`); the reverse mapping `E[E.A]` of a numeric enum from a static table, where a number with no member is a runtime error by requirements §3.8, since tsc types it `string` and Node gives `undefined`; a `switch` over the members, narrowed as a union of literals. Node's type stripping refuses an enum, so requirements §10 run the reference through tsc to JavaScript and then Node; Node 24 also has `--experimental-transform-types`. The plan picks one, and the diff runner learns it from the program's header; parameter properties of classes (T7.11) take the same path.
Where: requirements §2.2, §10; `src/parse`, `src/bind`, `src/check`, `src/lower`, `tests/runner/diff.odin`; [Differential tests](development.md#differential-tests).
After: none.
Done: diff programs use numeric, string and `const` enums, the reverse mapping and a `switch` over an enum, against the reference the runner takes for them; the development guide says how such a program runs; T2013 is retired.

### [ ] T7.8 `export default` and default imports

What: T2017 today (`src/parse/statements.odin:455` for `export default`, :432 for a default import, :595 for a `default` specifier). `export default function f`, `export default` of an expression, `import x from "./m"`, `import x, { y } from "./m"`, `{ default as x }` and `export { x as default }`. `default` is an ordinary export name, and the module resolution of T2.8 does not change. `export default class` comes with T7.11.
Where: requirements §2.2, §7; `src/parse/statements.odin`, `src/bind`, `src/check/modules.odin`.
After: none.
Done: a diff program over several modules exports a function, a constant and an expression as `default` and imports them under several names; a negative program pins a default import from a module without one, under a new T4xxx code; T2017 is retired.

## v2 wave 2: generics and classes

The rows "User generics via monomorphization" and "Classes, inheritance, `this`, getters and setters" of [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2). `check` already instantiates generic declarations for the lib, and `lower` interns layouts by structure, so an instance of a generic type is an ordinary object type. Classes need what the front end has nowhere yet: a class scope, `this` and `new`.

### [ ] T7.9 Generic interfaces and type aliases

What: `check` instantiates any declaration with type arguments (`interface_type`, `alias_type` and `bind_type_params` in `src/check/objects.odin`), and user files are held back in three places: `type_param_type` (`src/check/objects.odin`) and `resolve_type_params` (`src/check/resolve.odin`) answer nothing outside the lib, and `src/check/subset.odin` reports T2023. The task opens that for interfaces and type aliases, with constraints and defaults of type parameters (T2021 at `src/parse/types.odin:299` and :305), recursive generic types such as `List<T> = {head: T, tail: List<T> | null}`, `substitute` (`src/check/generics.odin`) instantiating a named generic object again, a cache for instances of an alias as `reserve_object` keeps one for interfaces, and a limit on the depth of instantiation, as tsc's TS2589 has. `lower` needs nothing new.
Where: requirements §2.2, §5; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), row "User generics via monomorphization"; `src/check/objects.odin`, `src/check/generics.odin`, `src/check/resolve.odin`, `src/check/subset.odin`, `src/parse/types.odin`.
After: none.
Done: diff programs build and print values of generic interfaces and aliases, a generic discriminated union and a recursive generic list; a negative program pins the depth limit under a new code.

### [ ] T7.10 Generic functions by monomorphization

What: generic function declarations, generic arrows (T2021 at `src/parse/expressions.odin:418`), explicit type arguments at a call (T2021 at :514), arguments inferred by `check_signature_call` (`src/check/generics.odin`), and a constraint whose fields the body reads. `lower` makes one IR function per distinct layout key of the type arguments, so two types of one layout share a function. How the body gets its facts goes to the operator before any code, since it touches the key decision "Shape of check facts": `check` types the body once over its type parameters, as tsc does, and `lower` puts the instance's arguments into every fact it reads; or `check` records facts per instance. A generic function used as a value is instantiated where its context fixes the arguments, and is a compile error where nothing does; a recursion that grows its type arguments, as `f<T>(x: T) { f([x]) }`, is a compile error at a limit.
Where: requirements §2.2, §3.5; [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Shape of check facts"; `src/check/generics.odin`, `src/check/resolve.odin`, `src/lower/lower.odin` (`declare_functions`), `src/lower/types.odin`.
After: T7.9.
Done: diff programs call generic functions over numbers, strings, objects and arrays, with inferred and explicit arguments, through a constraint and as values; a lower test pins one function per layout of the arguments and one shared by two types of one layout; a negative program pins the growing recursion; the IR of every program of `bench/ts` is the same as before.

### [ ] T7.11 Classes: fields, constructor, methods, `this`, `new`

What: `parse_class` skips the body of a class (T2009 at `src/parse/statements.odin:634`), `this` is T2009 (`src/parse/expressions.odin:601`), `new` is T2010 (:865), `instanceof` is T2021, and `bind` has no class scope and no `this`. A class with fields and their initializers, a constructor, parameter properties (`constructor(private x: number)`, which Node's type stripping refuses, so they take the reference path of T7.7), methods, `this` in methods and in the arrows inside them, `static` fields and methods, `private`, `protected`, `readonly` and `#private`, `new`, `instanceof`, `export default class`, and the strict rule that a field is set before the constructor ends. An instance is an object cell and its methods live once per class, not in the cell. A class needs an identity beyond its layout, since the console prints `Point { x: 1, y: 2 }` with the class name and the fields in creation order, and `instanceof` must tell two classes of one layout apart. A candidate: a table row per class (the rows of T5.7, `Program_IR.base`) that carries the name and a table of methods; this goes to the operator before any code. A method read as a value loses its `this` in Node, so it is a compile error with a hint to use an arrow. Until T7.26 a class with methods passes into no interface of its fields alone, by the exact-type rule.
Where: requirements §2.2, §3.3, §3.9; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), row "Classes, inheritance, `this`, getters and setters"; `src/parse/statements.odin` (`parse_class`), `src/bind/bind.odin`, `src/check`, `src/lower`, `src/abi/abi.odin` (`Type_Table`, `Function_Info`), `src/runtime/console/inspect.odin`.
After: T7.7.
Done: diff programs make, change, pass and print instances, call methods and static members, use `this` in arrows inside methods and test `instanceof`; a negative program per new code; requirements §3.3 say how an instance is laid out; T2009 and T2010 keep only what stays outside the subset.

### [ ] T7.12 Inheritance: `extends`, `super`, overriding

What: `class B extends A`, `super(...)` in the constructor, `super.m()`, overriding methods, abstract classes and methods (T2009 at `src/parse/statements.odin:150`), an instance of B where an A is expected, a method call through A dispatched on the class of the cell, `instanceof` along the chain. A read of a field through A on a B goes to the operator with the numbers of a probe, since it amends the key block "the layout is a function of structure": B's layout keeps A's fields at A's offsets, as C++ and Java do; or a read through A tests the layout in the header, as a union of objects does since T6.23 and a view since T6.24. A method call is direct where the whole program has one implementation of it.
Where: requirements §2.2, §3.3, §3.5; [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may); `src/lower/types.odin`, `src/lower/calls.odin`, `src/abi`.
After: T7.11.
Done: the numbers are recorded; diff programs run a hierarchy three levels deep with overriding, `super` calls and abstract methods, and an array of the base type holding several subclasses; a lower test pins the direct call where one class implements the method; requirements §3.3 and the key block say what changed.

### [ ] T7.13 Generic classes and `implements`

What: `class Stack<T>`, its type arguments inferred from the constructor's arguments or written out, its methods instantiated with the class by the monomorphization of T7.10, and `implements I` checked as assignability under the exact-type rule.
Where: requirements §2.2; `src/check`, `src/lower`.
After: T7.10, T7.11.
Done: a diff program uses a generic container class over numbers, strings and objects; a lower test pins one class per layout of the type arguments.

### [ ] T7.14 Getters and setters

What: T2021 `Getters_And_Setters` today, in object literals (`src/parse/expressions.odin:784`) and in types (`src/parse/types.odin:473`). Class accessors, static ones, and accessors a subclass inherits or overrides. TypeScript gives an accessor and a field the same type, so a read of `.x` through an interface that a class with an accessor flows into has to call it. That goes to the operator before any code: the read dispatches on the layout, as a view does since T6.24; or a flow of a class with accessors into a type read as a field is a compile error. The same answer covers accessors in object literals.
Where: requirements §2.2, §3.3; `src/parse`, `src/check`, `src/lower`.
After: T7.12.
Done: diff programs use class accessors, static, inherited and overridden ones, and the flows the operator accepts; the T2021 row is retired or narrowed to what stays out.

## v2 wave 3: exceptions

The row "`try`, `catch`, `throw`" of [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2): `ir`, `lower`, `codegen` and `rt/fail` change, and a block accepts unwind edges without a change of shape. A thrown error needs a class, so `Error` waits for T7.11 and T7.12.

### [ ] T7.15 Exceptions: the mechanism, measured

What: nothing unwinds today. `ir` has no exception edges, `codegen` marks every runtime function `nounwind`, and `src/llvm` declares no `LLVMBuildInvoke`, `LLVMBuildLandingPad` or `LLVMSetPersonalityFn`. Three candidates. LLVM landing pads cost nothing until a throw, but need a personality per platform (SEH on Windows, Itanium on Linux and macOS), unwind tables through the Odin frames of the runtime, and the exception-handling proposal on wasm. `setjmp` and `longjmp` per `try` cost something on entering every `try`, with one mechanism everywhere. A flag returned by every call that may throw, tested after the call as Swift and Go do, costs something on every such call, which a whole-program analysis limits to the calls that reach a `throw`, and works on wasm unchanged. The plan also answers which runtime errors become exceptions, those Node throws (`RangeError` for `Invalid string length`, `Invalid array length` and `Maximum call stack size exceeded`, `TypeError` for a `reduce` of an empty array), and which checks of requirements §3.8 stay fatal because Node runs on there; how the overflow handler, which runs on a stack of its own (T6.9), throws; and how a throw crosses the runtime when it calls back into the program (the sort comparator). A prototype measures the candidates on `raytracer` and on a `try` inside a hot loop, then the proposal goes to the operator.
Where: requirements §2.2, §3.8 (its closing paragraph), §6; [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Shape of our own IR"; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), row "`try`, `catch`, `throw`"; `src/ir/instructions.odin` (`Fail`), `src/codegen/module.odin`, `src/llvm`, `src/runtime/fail/fail.odin`, `src/runtime/overflow_windows.odin`, `src/runtime/overflow_posix.odin`.
After: none.
Done: the candidates and their numbers are recorded, and the operator's choice is on the board.

### [ ] T7.16 `throw`, `try`, `catch`, `finally`

What: T2011 today (`src/parse/statements.odin:739` for `throw`, :1050 for `try`). By the choice of T7.15: a `throw` of any value; `catch (e)` with `e` of type `unknown`, as `--strict` gives it, narrowed by `typeof` and `instanceof`; a `catch` without a binding; `finally` on every way out, `return`, `break` and `continue` included; a rethrow; a throw out of a closure, an inline loop of `map` or `filter`, and a sort comparator. `bind` and `check` carry the flow and the narrowing through `try`; the unwind edges of the IR are kept by every pass of `opt` and checked by `ir.verify`. A throw nobody catches writes one line through `fail` and exits with code 1; Node prints a stack instead, so expect programs pin it.
Where: requirements §2.2, §3.8; `src/bind/flow.odin`, `src/check/narrow.odin`, `src/ir`, `src/lower`, `src/opt`, `src/codegen`, `src/runtime/fail`.
After: T7.15, T7.11.
Done: diff programs throw and catch across functions, closures, inline loops and a comparator, with nested `try` and `finally` on every exit, green at both `-o` levels, under stress and ASan too; expect programs pin an uncaught throw of an object and of a number; T2011 is retired.

### [ ] T7.17 `Error` classes and catchable runtime errors

What: the lib gains `Error`, `TypeError`, `RangeError` and `SyntaxError`, with `message` and `name`, and a program can subclass them. The runtime errors T7.15 chose throw such objects with Node's messages. Two answers go to the operator: `e.stack`, whose frames a compiled program cannot reproduce as Node prints them, and `console.log(err)`, for which Node prints the stack.
Where: requirements §3.8 (its closing paragraph), §3.9; `src/lib/lib.d.ts`, `src/runtime/fail`, `src/runtime/console`.
After: T7.16, T7.12.
Done: diff programs catch `Invalid array length`, `Invalid string length` and `Maximum call stack size exceeded` as `RangeError` with Node's message, and subclass `Error`; expect programs pin the errors that stay fatal; requirements §3.8 say which errors a `catch` sees.

## v2 wave 4: tables

The row "Index signatures, `Object.keys`, `for...in`, `obj[key]`, `Map` and `Set`" of [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2): `rt/table`, `lower`, `abi` and `check` change, and `Runtime_Proc` grows by rows. `Map` and `Set` need `new` from T7.11 and their entries need the tuples of T7.4.

### [ ] T7.18 `rt/table`: hash tables in the GC heap

What: the runtime package [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime) lists as `table` (v2). `Map` and `Set` iterate in insertion order, an iteration sees the entries added during it, and an entry deleted during it is skipped, so the table is ordered, as Tyler Close's deterministic hash table and V8's OrderedHashTable are: entries in an array in insertion order, buckets of indices, deleted entries marked and dropped when the table is rebuilt. Keys compare by SameValueZero (`NaN` equals `NaN`, `-0` equals `0`), strings hash by their units, references by address, since a cell never moves. Whether entries are tagged slots or unboxed by the table's type, as the element tables of arrays are, goes to the operator. The table cell has a type table of its own, and `abi` gains its rows.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `table`; requirements §4.5; `src/abi/abi.odin` (`Cell_Kind`, `Type_Table`), `src/abi/calls.odin`, `src/runtime/gc`.
After: none.
Done: a table test pins the order through deletes and growth, SameValueZero keys and an iteration that sees what was inserted during it; the collector traces keys and values under stress and ASan.

### [ ] T7.19 `Map` and `Set`

What: the lib declares `Map<K, V>` and `Set<T>`, which `new` creates as a built-in class. `get`, `set`, `has`, `delete`, `clear`, `size`, `forEach`, `keys`, `values` and `entries`; `for...of` over a map, whose entries are tuples (T7.4) a pattern takes apart (T7.5), and over a set; spread; `new Map(entries)` and `new Set(array)`. An iterator as a value goes to the operator: only where `for...of`, spread or a constructor consumes it, a compile error elsewhere; or an iterator cell in the runtime. The console prints `Map(2) { 'a' => 1, 'b' => 2 }` and `Set(1) { 1 }`, as Node does.
Where: requirements §2.2, §3.9; `src/lib/lib.d.ts`, `src/lower/lib.odin` (`LIB_STRATEGIES`), `src/runtime/table`, `src/runtime/console/inspect.odin`.
After: T7.18, T7.11, T7.5.
Done: diff programs call every method with keys of each kind (numbers with `NaN` and `-0`, strings, objects), iterate while adding and deleting, and print maps and sets nested in objects and arrays; `bench/ts` gains a program over `Map` with its Go twin, and `bench/RESULTS.md` its row.

### [ ] T7.20 Index signatures and `Record`

What: T2021 `Index_Signatures` today (`src/parse/types.odin:464`), and `check_index` (`src/check/expressions.odin`) indexes only arrays and strings. `{[k: string]: T}` and `Record<string, T>` as a table cell: `d[k]` read and written, `k in d` (T2021 `In_Expressions`), enumeration in the order Node gives an object, keys that look like integers first, and an object literal given to such a type. Two answers go to the operator. A missing key: tsc types the read `T` and Node gives `undefined`, so it is a runtime error by requirements §3.8, or the read is typed `T | undefined`. And `delete d[k]`, which §2.2 lists under "never".
Where: requirements §2.1, §2.2, §3.8; `src/parse/types.odin`, `src/check/expressions.odin` (`check_index`), `src/lower`, `src/runtime/table`.
After: T7.18.
Done: diff programs build, read, write, test, enumerate and print dictionaries with keys of both kinds; the requirements say what a missing key does; the T2021 row is retired.

### [ ] T7.21 `Object.keys`, `Object.values`, `Object.entries`, `for...in`, `obj[key]`

What: `for...in` is T2019 today (`src/parse/statements.odin:896` and :927), and `Object` is not in the lib. For an object of a fixed layout the keys are the field names of its type table in Node's order, which the console already follows, without an optional field that was never set; `for...in` walks them. `keyof T` (T2021 `Keyof_Types`) and `obj[k]` with `k: keyof T`: a switch over the names where the layout is known, a lookup in the type table where it is not. `Object.entries` gives `[string, T][]`. For a dictionary of T7.20 they walk the table.
Where: requirements §2.2, §3.9; `src/lib/lib.d.ts`, `src/parse/statements.odin`, `src/check`, `src/lower`, `src/runtime/console/inspect.odin`.
After: T7.20, T7.4.
Done: diff programs enumerate objects with names that look like integers, optional fields set and unset, and dictionaries, and read fields by a `keyof` key; T2019 is retired.

## v2 wave 5: `async`

The row "`async` and `await`" of [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2): `lower`, `ir` and `rt/sched` change, and a continuation is a closure. Timers stay out (requirements §12), so the program itself settles every promise, and the queue of microtasks runs once the modules have run.

### [ ] T7.22 `async`: the mechanism, measured

What: two candidates. A state machine in `lower`: an async function becomes a closure whose environment on the heap holds its locals and the point to resume at, and each `await` returns to the scheduler, as C#, Rust and Hermes do. Or a stack of its own for each async call, switched by the runtime, which the conservative scan must walk for every suspended call, which takes memory per call, and which wasm cannot do without the stack-switching proposal. A rejected promise throws at the `await`, so the mechanism of T7.15 is part of it. The order of microtasks must be Node's exactly. A prototype measures both, then the proposal goes to the operator.
Where: requirements §2.2, §6; [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `sched`; `src/lower/closures.odin`, `src/runtime/gc/collect.odin` (`mark_stack`).
After: T7.16.
Done: the candidates and their numbers are recorded, and the operator's choice is on the board.

### [ ] T7.23 `rt/sched`: promises and the queue of microtasks

What: `Promise` in the lib with `new Promise`, `then`, `catch`, `finally`, `Promise.resolve`, `Promise.reject`, `Promise.all`, `Promise.allSettled` and `Promise.race`; the promise cell; the queue, which lives in the heap, the only runtime state, and which `rt.main` drains after `tsnc_main`. A rejection nobody handles ends the program with code 1. The console prints `Promise { 1 }` and `Promise { <pending> }`.
Where: requirements §2.2, §3.9; [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `sched`; [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may), the item on the GC heap; `src/runtime/rt.odin`, `src/abi/calls.odin`, `src/lib/lib.d.ts`.
After: T7.22, T7.11.
Done: diff programs chain `then`, `catch` and `finally` and mix settled and rejected promises with `Promise.all`, printing in the order Node prints; an expect program pins an unhandled rejection.

### [ ] T7.24 `async` functions and `await`

What: T2012 today, at `src/parse/statements.odin:155`, :506 and :873 and at `src/parse/expressions.odin:380`, :788, :888 and :969. By the choice of T7.22: async declarations, arrows and methods, which return a `Promise<T>`; `await` in expressions, in loops, in `try` with a rejection, and in recursion. The plan weighs a top-level `await` in the entry module; `for await` stays T2012.
Where: requirements §2.2; `src/parse`, `src/check`, `src/lower`.
After: T7.23.
Done: diff programs await in loops, in `try`, in recursion, and run two async functions whose steps interleave in Node's order; T2012 keeps only `for await`.

## v2 wave 6: structural typing

The row "Full structural typing via fat pointers" of [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2) and requirements §3.3: an object passes where a type of fewer fields is expected. T7.1 counts how often the exact-type rule rejects real code; classes add an instance passed where an interface of part of its members is expected.

### [ ] T7.25 Structural typing: the representation, measured

What: two candidates, measured on a probe and on `raytracer`. The fat pointer of requirements §3.3: a reference and a table of field offsets, 16 bytes, as Go's interface value with its itab, made where an object passes into a type of fewer fields. Or the views of T6.24 carried further: a place of the narrower type holds a cell of any layout that has its fields, and a read tests the layout in the header and loads at that layout's offset, 8 bytes and a test per read; the whole program bounds the set of layouts that reach a type. An extra field of a fresh object literal stays T3011, as tsc reports it. The proposal goes to the operator; it amends requirements §3.3 and maybe the row of the table.
Where: requirements §3.3, §13; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), row "Full structural typing via fat pointers"; `src/check/types.odin` (`object_assignable`), `src/lower/classes.odin`, `src/lower/unions.odin`.
After: T7.1, T7.12.
Done: the candidates and their numbers are recorded, and the operator's choice is on the board.

### [ ] T7.26 An object where a type of fewer fields is expected

What: by the choice of T7.25, `{x, y, z}` passes where `{x, y}` is expected through an assignment, an argument, a result and an array element, a write through either type shows through the other, and a class instance passes into an interface of part of its members. The exact-type rule keeps only the extra field of a fresh literal.
Where: requirements §3.3; `src/check`, `src/lower`, and `src/ir` and `src/abi` if the choice adds a type.
After: T7.25.
Done: diff programs pass objects and instances through every flow and write through both types; `raytracer` and `objects` are measured before and after and lose nothing where layouts match; requirements §3.3 say what changed and §13 loses the row on the exact-type rule.

## v2 wave 7: tools and the collector

The rows "Debug info", "N codegen units and ThinLTO", "Cross-compilation and `wasm32-wasi`", "Concurrent GC with write barriers" and "NaN-boxing, precise roots, shadow stack" of [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2). Debug info, codegen units and the Linux build from Windows touch no language code and can start beside the earlier waves; wasm needs the exceptions of wave 3.

### [ ] T7.27 Debug info: line tables

What: every IR instruction keeps its span for this (`src/ir/instructions.odin`), `codegen` never reads it, and `src/llvm` declares nothing of `DebugInfo.h`. A `-debug` flag, as Odin has; a compile unit, a file per module, a subprogram per function, a location per instruction, and `inlinedAt` for a body `opt` inlined (T6.20), whose spans are the callee's. On Windows `lld-link` writes a PDB under `/DEBUG`; elsewhere the object carries DWARF, and the plan weighs `dsymutil` on macOS, where the debug map points into the temporary object, and a runtime object built with debug info.
Where: requirements §9 (artifacts); [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), row "Debug info"; `src/codegen`, `src/llvm`, `src/link/link.odin`, `src/target`, `src/main.odin`.
After: none.
Done: a codegen test pins the location of each kind of instruction in `-emit-llvm`; a breakpoint on a TypeScript line stops there in the debugger of each OS, checked by hand and recorded; the development guide says how to debug a program.

### [ ] T7.28 Debug info: variables and types

What: locals and parameters through the debug records of LLVM 20, with a type per IR type: `double` for f64, a string with its units, an object as a struct of the fields its type table lists, a tagged value as its tag and payload. At `-o:none` every local is visible.
Where: `src/codegen`, `src/llvm`.
After: T7.27.
Done: a codegen test pins one variable of each IR type; a local of each type shows its value in a debugger, checked by hand.

### [ ] T7.29 N codegen units

What: `ir.finish` makes one unit of every function (`src/ir/build.odin`), and `driver` passes `p.units[0]` (`src/driver/build.odin`); `declare_funcs` already declares a function outside the unit as external. `add_type_tables`, `add_roots`, `add_ascii_cells` and `add_heap` define `tsnc_type_tables`, `tsnc_roots`, `tsnc_ascii_cells` and `tsnc_heap` in every module, which N units would define N times: one unit defines them and the others declare them, and globals and string cells that several units read get hidden linkage. The split is a function of the program, not of `-j`, so the executable stays the same at any thread count. `codegen.emit` runs per unit on the pool, each with its own context, module and target machine (requirements §8), and `link.link` already takes a list of objects. The task measures compile time at `-o:speed` with `bench/runner compile` and `raytracer`, and the run time the split loses where LLVM no longer inlines across units; `opt` has inlined small callees before the split.
Where: requirements §8; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), row "N codegen units and ThinLTO"; [Interaction map](architecture-plan-tsnc.md#interaction-map), the `driver` to `codegen` row; `src/ir/build.odin`, `src/codegen/module.odin`, `src/driver/build.odin`.
After: none.
Done: the determinism test gives a byte-identical executable at `-j:1` and `-j:8` with several units; compile time and run time are measured before and after and go to the PR.

### [ ] T7.30 The runtime as bitcode in the program's module

What: the review of 2026-10-03 left this to the codegen units: a small export (`String_Equal`, `String_Char_Code_At`, the `Math` rows) still costs a call, where the runtime built as LLVM bitcode and linked into the program's module (`LLVMLinkModules2`, which `src/llvm` does not declare) lets LLVM inline it. The exports keep `@(require)` and the runtime keeps `main`; the ASan build needs the same path. A prototype measures `chars`, `strings` and `raytracer`, then the proposal goes to the operator.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `rt`; requirements §4.3; `src/codegen`, `src/llvm`, `src/link`, `tests/all.sh`, the CI workflow.
After: T7.29.
Done: the numbers are recorded; if the operator accepts the change, the corpora are green in all passes, under stress and ASan too, and the three benchmarks are measured before and after.

### [ ] T7.31 ThinLTO across codegen units

What: once the units exist, ThinLTO would inline across them again. LLVM-C 20 has no ThinLTO API: it writes no module summary, and libLTO is a library of its own. LLD runs ThinLTO itself over bitcode objects that carry a summary, but Linux and macOS link through `cc`. The task first proves a path with a prototype, and may close by recording that LLVM-C offers none; `opt` already inlines across modules before the split.
Where: requirements §8; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), row "N codegen units and ThinLTO"; `src/codegen`, `src/llvm`, `src/link`.
After: T7.29.
Done: the result of the prototype is recorded; if a path exists and pays, it is built, the executable stays byte-identical at any `-j`, and compile and run time are measured.

### [ ] T7.32 Linux executables from Windows

What: `link` refuses a target other than the host and `driver` reports `Cross_Link`. `E:/Odin/dist/bin` has no `ld.lld`, but `lld-link.exe` is the one LLD binary, which links ELF in its GNU flavor; Odin cross-builds the runtime object with `-target:linux_amd64`. Where the C runtime files and libc come from goes to the operator: a static musl that a sysroot names, a sysroot copied from Linux, or a runtime that needs no libc. macOS stays a native build only (requirements §9).
Where: requirements §9; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), row "Cross-compilation and `wasm32-wasi`"; `src/target/target.odin`, `src/link/link.odin`, `src/driver/build.odin`; [Linking](development.md#linking); the CI workflow.
After: none.
Done: CI builds a program on Windows for `linux_amd64` and runs it on Linux with the output of the native build; the development guide says what such a build needs.

### [ ] T7.33 `abi` sizes from `Target`

What: the contract of [ABI](architecture-plan-tsnc.md#abi-package-abi) says that for wasm32 a procedure of `Target` computes sizes and offsets, and the runtime checks its structs against it with `#assert`. Today `codegen` takes them from `size_of` and `offset_of` of the host's structs (the asserts in `src/codegen/module.odin`): the cell header, `String_Cell.length` as an `int`, slots, the offsets of the type tables. Every size and offset that generated code uses becomes a function of the target's `pointer_size`, the rows of the host unchanged.
Where: [Contracts](architecture-plan-tsnc.md#contracts), ABI, "Ownership"; `src/abi`, `src/ir/build.odin`, `src/lower/types.odin`, `src/codegen/module.odin`, `src/target`.
After: none.
Done: an abi test pins the wasm32 layout of every cell kind; the IR and the object of every corpus program on the host are the same as before.

### [ ] T7.34 Precise roots through a shadow stack

What: the fallback of requirements §6, which wasm needs: the locals of a wasm function live outside its linear memory, so the conservative scan finds none, and `src/runtime/gc/registers.odin` builds only on amd64 and arm64. Codegen keeps each reference a function holds across a call that may collect in a frame record, pushed on entry and popped on return and on unwinding (T7.16); `mark_stack` walks the records instead of the stack. LLVM's `llvm.gcroot` stays rejected. How the corpora test it on a native target without a new mode flag goes to the operator.
Where: requirements §6, §13, §3.4; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), row "NaN-boxing, precise roots, shadow stack"; `src/codegen`, `src/runtime/gc/collect.odin`, `src/abi`.
After: T7.16.
Done: on a native target the corpora pass with the shadow stack as the only roots on the stack, under stress too; its cost on `trees`, `objects` and `raytracer` is measured; requirements §6 say where it is used.

### [ ] T7.35 `wasm32-wasi`

What: `Target` reserves `wasm32_wasi` with no row in `SPECS`, and `wasm-ld.exe` is in `E:/Odin/dist/bin`. The runtime for WASI: a heap that grows linear memory, where the native one reserves 64 GiB of address space (`src/runtime/gc/heap.odin`); no stack overflow handler; arguments, environment and exit through WASI; the console without its Windows paths; exceptions by the mechanism of T7.15, roots by T7.34. Node runs a wasm32-wasi program through `node:wasi`, so the runner can run the corpora under it.
Where: requirements §2.2, §9; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), row "Cross-compilation and `wasm32-wasi`"; `src/target`, `src/link`, `src/runtime`, `tests/runner`.
After: T7.33, T7.34, T7.16.
Done: the diff and expect corpora pass on wasm32-wasi under Node in CI, and the plan lists what stays out and why.

### [ ] T7.36 `gc`: concurrent marking

What: requirements §6 name concurrent tri-color marking for v2, as in Go, with a barrier of its own beside the generational one. T6.8 left it out: it hides pauses rather than saving work, and the longest pause was 11 ms. A marker thread ends "one mutator" in §6, touches the key block on the GC heap, and has no thread to run on under wasm. The task first measures pauses on `trees`, `objects`, `raytracer` and a program with a large live heap, then brings them and a proposal to the operator.
Where: requirements §6; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), row "Concurrent GC with write barriers"; [Risks and open questions](architecture-plan-tsnc.md#risks-and-open-questions), the item on the cost of the collector; `src/runtime/gc`, `src/codegen` (`build_barrier`).
After: none.
Done: the pauses are recorded; for what the operator accepts, a gc test pins each new invariant and the corpora are green under stress and ASan.

### [ ] T7.37 NaN-boxing

What: requirements §3.4 allow a tagged value in 8 bytes for v2, only together with precise roots, since a boxed pointer is hidden from the conservative scan (§6). The plan's risk item counts about 250 references in `abi`, `lower`, `codegen` and the runtime, and the 16 bytes of a number that may be `undefined`. The task first measures what tagged slots cost in memory and time on the benchmarks, then brings a proposal to the operator.
Where: requirements §3.4, §6; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), row "NaN-boxing, precise roots, shadow stack"; `src/abi`, `src/lower`, `src/codegen`, `src/runtime`.
After: T7.34.
Done: the measurement is recorded; for what the operator accepts, the corpora are green in all passes, under stress and ASan too, and the benchmarks are measured before and after.

## v2 wave 8: RegExp, bigint, files, strings

The rows "`RegExp`, `bigint`, file I/O" and "Hybrid Latin-1 and UTF-16 storage" of [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2): new runtime packages and lib declarations. Each of them throws Node's errors, so they come after wave 3.

### [ ] T7.38 Files and stdin

What: requirements §2.2 give v2 reading and writing a whole file and reading stdin. The API is Node's, so diff programs compare: `readFileSync(path, "utf8")`, `readFileSync(0, "utf8")` for stdin and `writeFileSync(path, text)` from `node:fs`. `node:fs` is a bare specifier, which §7 does not resolve, so a built-in module declares it; how goes to the operator. A file that is missing throws Node's `ENOENT` error (T7.17). The runtime package `fs` does the work, and the diff runner gains a header that feeds stdin.
Where: requirements §1, §2.2, §7, §12; [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `regex`, `bigint`, `fs`; `src/lib`, `src/driver` (module resolution), `src/runtime`, `tests/runner/diff.odin`.
After: T7.17.
Done: diff programs write a file and read it back, read stdin, and catch the error of a missing file with Node's message; the development guide documents the header.

### [ ] T7.39 `bigint`

What: `10n` is T1005 today (`src/parse/tokenize.odin:288`) and the type `bigint` T2021 (`src/parse/types.odin:217`). Literals, `+ - * / % **`, unary `-`, comparisons between bigints and with numbers, `===`, bitwise operators and shifts, `BigInt(n)`, `toString(radix)`, `Number(b)`, `typeof`, and the console's `10n`. A `BigInt` tag joins `abi.Tag`. Division by `0n` throws a `RangeError`. The runtime package `bigint` keeps an immutable cell of digits, with `core:math/big` as the engine on a scratch allocator and the digits copied into the cell (requirements §4.5).
Where: requirements §2.2, §4.5; [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `regex`, `bigint`, `fs`; `src/parse/tokenize.odin`, `src/abi`, `src/lower`, `src/runtime/value`, `src/runtime/console`.
After: T7.17.
Done: diff programs compute past 2^64, divide and take remainders of both signs, compare bigints with numbers, and print in several radixes and nested in objects.

### [ ] T7.40 `rt/regex` and `RegExp`

What: requirements §4.5 rule out `core:text/regex`, which has no lookahead, lookbehind or backreferences. An engine of our own for the ECMAScript dialect, backtracking as Node's is: classes, greedy and lazy quantifiers, groups and named groups, backreferences, lookahead and lookbehind, anchors, the flags `g i m s u y`, case folding from tables generated as T5.3's are. A literal's pattern is parsed at compile time, so a bad one is a compile error, as Node reports it before running; the tokenizer, which reads every `/` as division (`src/parse/tokenize.odin`), has to tell a pattern from a division by context, and T2020 (`src/parse/expressions.odin:920`) goes. `new RegExp(s)` throws `SyntaxError` at run time. `test`, `exec`, `lastIndex`, `source`, `flags`, and the console's `/a+/g`; the match array of `exec`, an array with `index` and `groups`, goes to the operator.
Where: requirements §2.2, §4.5; [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `regex`, `bigint`, `fs`; `src/parse`, `src/lib/lib.d.ts`, `src/runtime`.
After: T7.11, T7.17.
Done: a regex test runs the engine over a table of patterns and subjects whose answers came from Node; diff programs use literals and `new RegExp`; T2020 is retired.

### [ ] T7.41 String methods with `RegExp`

What: `match`, `matchAll` by the iterator rule of T7.19, `replace` and `replaceAll` with string and regex patterns, `$1`, `$&` and `$<name>` in the replacement and a function as replacer, `split` by a regex with a limit, and `search`.
Where: requirements §2.2; `src/lib/lib.d.ts`, `src/lower/lib.odin`, `src/runtime/str`, `src/runtime/regex`.
After: T7.40, T7.19.
Done: diff programs run each method over ASCII, Cyrillic and emoji subjects with every flag.

### [ ] T7.42 Strings of Latin-1 units

What: requirements §3.2 give v2 strings of one byte per unit where every unit fits, as V8 stores them, with the semantics unchanged. A string is read in many places: `String_Cell` in `abi`, `str`, the inline `Unit_Load` and the static cells of `codegen`, `Ascii_Cell`, `String_Join`, and fifteen calls of `str.units` in the console; every inline read would test a width flag in the header. The task first measures memory and time with a prototype on `strings`, `chars` and the parser of `raytracer`, then brings a proposal to the operator.
Where: requirements §3.2; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), row "Hybrid Latin-1 and UTF-16 storage"; `src/abi/abi.odin` (`String_Cell`), `src/runtime/str`, `src/codegen/instructions.odin`, `src/runtime/console`.
After: none.
Done: the measurement is recorded; for what the operator accepts, the corpora are green in all passes, under stress and ASan too, and requirements §3.2 say what changed.

### [ ] T7.43 Close milestone 7

What: run the programs of T7.1 again and put the counts beside the first ones. The v2 list of requirements §2.2 matches what was built, the README's Status says that v2 is done, and what the waves left open moves to [Risks and open questions](architecture-plan-tsnc.md#risks-and-open-questions).
Where: the report of T7.1; requirements §2.2; `README.md`; [Risks and open questions](architecture-plan-tsnc.md#risks-and-open-questions).
After: every other task of milestone 7.
Done: the report has its second run; the README and the requirements agree with the code.

## v1 critical path

T1.1 → T1.3 → T1.5 → T1.6 → T1.7 → T1.8 → T1.9 → T2.2 → T2.3 → T2.4 → T2.5 → T2.7 → T2.8 → T3.1 → T3.2 → T3.3 → T3.4 → T3.5 → T3.6 → T4.1 → T4.2 → T4.3 → T4.4 → T4.5 → T4.7 → T5.1 → T5.2 → T5.3 → T5.4 → T5.5 → T5.7 → T5.8 → T5.9 → T5.10 → T6.1 → T6.2.

Running in parallel with the critical path: T1.2 and T1.4 (after T1.1), T2.1 and T2.6, T4.6 (after T1.5), T5.6, T6.3. T5.11 to T5.17 run between T5.10 and T6.1: they change tests, the runner and comments, not what the compiler does. T6.4 to T6.8 come after T6.3 and before the v2 waves; T6.4 and T6.5 share no code and can run in parallel; T6.7 and T6.8 both follow T6.6 and both change `codegen`, so they run one after the other.

T6.15 to T6.28 come from the review of 2026-10-03 and run before the v2 waves too. T6.16, T6.17, T6.20 and T6.21 all change `opt` and run one after the other; so do T6.15 and T6.25 in `codegen`, and T6.22 to T6.24 in `lower`. T6.18, T6.26 and T6.27 are runtime work that shares no code with the compiler tasks, apart from the element size T6.26 changes in `codegen`.

The waves of milestone 7 run in numeric order, T7.1 first. T7.27, T7.29, T7.32, T7.33 and T7.42 touch no language code and can run beside the language waves. Tasks that change one package run one after the other, as in milestone 6: most language tasks change `check` and `lower`, and T7.16, T7.27 to T7.30 and T7.34 all change `codegen`.
