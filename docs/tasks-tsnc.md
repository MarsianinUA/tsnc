# Task board: tsnc

Source: `architecture-plan-tsnc.md` (section "Milestones") and `REQUIREMENTS.md` v0.1. Updated: September 28, 2026.

Purpose. The operator gives the agent a task number. The agent reads the shared handoff kit and the task kit, makes a detailed plan and writes the code. Tasks do not change the architecture. If a task runs into a key block from the section [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may), the work stops and the question goes back to the operator.

## How to use

Operator prompt template for the agent:

> Do task T2.4 from `docs/tasks-tsnc.md`. First read the shared handoff kit and the task kit. Then run `$direct-plan` on the links in the "Where" line, then `$direct-writer`. The done criterion is the task's "Done" line. Do not change the key blocks of `architecture-plan-tsnc.md`. If in doubt, stop and ask.

Statuses in the task heading: `[ ]` not started, `[~]` in progress, `[x]` accepted, `[!]` blocked (append the reason to the line). The operator changes the status.

Order. Milestones run strictly in numeric order. Inside a milestone the "After" line sets the dependencies. Different agents can work in parallel on tasks that share no dependencies.

## Shared handoff kit

Every agent reads it before any task.

1. `architecture-plan-tsnc.md`: sections [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), [Key decisions](architecture-plan-tsnc.md#key-decisions), [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may); the rows for your packages in [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler) or [runtime](architecture-plan-tsnc.md#package-boundaries-runtime); your [Contracts](architecture-plan-tsnc.md#contracts).
2. `REQUIREMENTS.md`: §11 (build with `-vet -strict-style`, all repository text in English, repository structure) and the sections from the task's "Where" line.
3. Skills: `$direct-plan`, then `$direct-writer`. Rules: `$direct-principles`, `$design-language`, `$code-conventions`. Before handing in: `$code-review-and-quality`.
4. Commands from the root of `projects/tsnc`:
   - compiler: `odin build src -out:dist/tsnc.exe -o:speed -vet -strict-style`;
   - package check: `odin check src/<package> -no-entry-point -vet -strict-style` (drop `-no-entry-point` for a package with `main`);
   - package tests: `odin test tests/<package> -out:dist/<package>-tests.exe -vet -strict-style`; unit tests of `src/<package>` live in `tests/<package>/`, never next to the code;
   - runtime: `odin build src/runtime -build-mode:obj -use-single-module -o:speed -out:dist/tsnc_rt-<target>.obj -vet -strict-style` (without `-use-single-module` Odin writes one `.obj` per package);
   - runs: `odin run tests/runner -out:dist/runner.exe -- smoke | negative | diff`.
5. General done criterion for any task: `odin check` and `odin test` of the affected packages are green; no new package, mode flag, package-level state or import against the pipeline beyond the plan; every new diagnostic has a code in the `diag` registry and a hint; all text in English: comments, documentation, compiler messages; the agent makes no commits.
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
Where: requirements §3.2, §3.7; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `lower` and `abi`; `bench/ts/chars.ts`, `bench/ts/strings.ts`.
After: T6.3.
Done: the corpora are green in all passes, under stress and ASan too; a lower test pins each decision the way T5.16 pins them (no runtime call where the plan says none); `chars` runs in at most 1.5 times Node's time.

### [x] T6.5 `T | null` of one reference type as a plain pointer

What: `trees` takes 1.124 s against 0.342 for Node and 0.352 for Go. A union with an object member is a 16-byte tagged slot (requirements §3.4, and the item settled in T5.7 under [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may)), so the node `{left: Tree | null, right: Tree | null}` is a 40-byte cell in the 48-byte size class, against 16 bytes in Go, and the collector marks three times the memory. A union of one reference type (an object, array, string or function type) with exactly one of `null` and `undefined` becomes one pointer slot, 0 meaning that `null` or `undefined`, with its narrowing a compare with 0. Where such a value flows into `any`, a wider union or the console, lower gives it its tag. The layout stays a function of structure. The task amends requirements §3.4 and the T5.7 item, so the operator approves the plan before any code.
Where: requirements §3.3, §3.4, §6; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `lower`, `codegen`, `abi`; the `gc` type table format; `bench/ts/trees.ts`.
After: T6.3.
Done: the corpora are green in all passes, under stress and ASan too; a lower test pins that such a slot carries no tag; the node of `trees` is a 24-byte cell; requirements §3.4 and the architecture plan say what changed.

### [x] T6.6 A cheaper entry into the runtime

What: every export starts with `export_context()` (`runtime.default_context()` and two fields, `src/runtime/rt.odin`) and a `DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD`, although most hot exports (`String_Equal`, `String_Char_Code_At`, the `Math` rows, what T6.4 leaves of `String_At`) touch no scratch memory and fail only through an `ensure`. First measure what the two cost per call and what share of `chars`, `strings` and `closures` that is after T6.4. Candidates: a guard only in the exports that use scratch memory; a context built only on the failure path. A third follows the same entry into allocation: every object, array and closure environment is a call to `tsnc_alloc`, which after the entry looks up the type table, checks the trigger, pops the free list of the class, poisons and zeroes, and `trees` makes 29.4 million of them (`bench/bench.sh -gc`). V8 inlines that fast path into generated code and calls the runtime only when a page is full. Here generated code would pop the free list itself, so it reads the heap, and the runtime cannot hand it a data symbol (T6.4). "Setting up `context` in the exports" and "the GC heap as the only runtime state" are key blocks of [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may), so the measurement and the proposal go to the operator before any code.
Where: requirements §4.3, §4.5; [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime); `src/runtime/exports.odin`.
After: T6.4.
Done: the measurement is recorded in the plan; if the operator accepts a change, the corpora are green in all passes, under stress and ASan too, the benchmarks it targets are measured before and after, and the key block's text says what changed.

### [x] T6.7 `opt`: integer narrowing, escape analysis, bounds check elimination

What: Go runs `collatz` in 0.180 s against tsnc's 0.744 and `sieve` in 0.033 against 0.157. Every counter, index and bitwise operand is an f64 converted on each use, a bounds check stands before every element access, and every object, array and closure environment goes to the GC heap (`closures` 0.260 against Node's 0.192: an environment per pass). The package `opt` from [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler) appears: `optimize(^Program_IR, level)`, IR to IR, called by `driver` between `lower` and `codegen`, the only phase that mutates its input. Three passes. Integer narrowing keeps a value the pass proves always an integer in the safe range in `I32` or `I64`, which join the closed set of IR types, and `codegen` maps them; behaviour does not change (requirements §3.1, the Static Hermes precedent). Escape analysis puts an object, array or closure environment that never leaves its function on the stack or splits it into SSA values, so it never reaches the collector (§4.1 item 4). Bounds check elimination removes a `Bounds_Check` the analysis proves, as an instruction, so `codegen` never guesses. This was epic E7.1 of milestone 7. Each pass is a subtask of its own with a corpus program that shows the win; the split goes to the operator first, as the epic's first step would have.
Split (operator, 2026-10-01): T6.7.0 the groundwork (`ir.Flow`, `ir.operands`, the package, the driver call) and `x % ±2^k` without `fmod`; T6.7.1 the range analysis and narrowing to `I32` and `I64`; T6.7.2 `Proved_Index`; T6.7.3 cells on the stack, which LLVM splits into registers. What stays out: `x = 3x + 1` of `collatz`, which nothing bounds; the per-pass box of a `for` header `let` a closure captures, which reaches the next pass through a phi, so `i % 10` in `closures` stays f64; the checks of `sieve`, whose `j <= LIMIT` tests no length.
Where: requirements §2.2 (the v2 list), §3.1, §4.1 item 4, §13 (the f64 row); [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `ir`, `opt`, `codegen`, `driver`; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), rows "Integer optimization of `number`" and "Escape analysis and bounds check elimination"; `bench/ts/collatz.ts`, `bench/ts/sieve.ts`, `bench/ts/closures.ts`, `bench/ts/objects.ts`.
After: T6.6.
Done: the corpora are green at both `-o` levels, in all passes, under stress and ASan too; a test per pass pins its decision on a small IR the way T5.16 pins lower's; `-emit-ir` shows the pass's result; the four benchmarks are measured before and after, and the numbers go to the PR; requirements §3.1 and the plan's row `opt` say the package exists.

### [ ] T6.8 Concurrent GC with write barriers; NaN-boxing and precise roots by the numbers

What: `trees` takes 0.75 s after T6.5 against 0.342 for Node and 0.352 for Go. The program builds 24-byte cells in the 32-byte class and drops them, thirty million next to a live tree of 262 thousand, so it measures the allocation path and the collector and nothing else. The v1 collector stops the program, marks the whole live set on every collection, the long-lived tree included, and sweeps every page; a collection comes when the heap has doubled since the last one (`src/runtime/gc/heap.odin`, `GROWTH` and `MIN_TRIGGER`). Requirements §6 name the v2 collector: concurrent tri-colour marking with write barriers in generated code, as in Go. `Field_Store_Ref` and `Element_Store_Ref` are separate IR instructions for this reason: the barrier is their new implementation in `codegen`, and the marker keeps its state inside the heap, which stays the only runtime state. The two other rows of the epic, NaN-boxing (a tagged value in 8 bytes, not 16) and precise roots through a shadow stack in place of the conservative scan (§6, the fallback), were "depending on benchmark results". So far the numbers point at the collector, not at the tagged layout: since T6.5 the hot union of `trees` carries no tag. The task starts with a measurement: how many collections `trees` runs, and how its time splits between the allocation entry (after T6.6), marking and sweeping. `bench/bench.sh -gc` gives the collector's side. On 2026-09-30 it read 109 collections, 0.3 s of marking and 0.09 s of sweeping out of 0.8 s, and 10.6 MB live after the last collection, so marking is where the time goes. Three candidates outside the epic come with it. Generations without moving: mark bits stay set between collections (sticky mark bits), and a minor collection traces only the cells allocated since the last one plus those the write barrier recorded, so the barrier the concurrent marker needs serves twice (Demers et al. 1990 for conservative collectors, sticky Immix in Jikes RVM). §6 lists only concurrent marking for v2, so this one amends it. A 24-byte size class: `CLASS_SIZE` steps by 16 to keep cells 16-byte aligned, so the 24-byte node takes a 32-byte slot and a quarter of what sweep walks is padding. Go has the class; before adding it, check that no cell needs more than 8-byte alignment and how the ASan poisoning of T5.10 treats the slot. The growth policy: the live tree alone puts the trigger at twice 10.6 MB, above `MIN_TRIGGER`, so `GROWTH` decides how many times the same tree is marked; V8 lets its young generation grow to tens of megabytes first. T6.6 left a fourth: allocating inline in generated code, worth at most about 2.4 ns of the 3.4 a cell takes (the plan's risk item on entering the runtime). Then a proposal of which of these to build, in what order, to the operator. This was epic E7.11 of milestone 7. It touches the key blocks "The GC heap as the only runtime state" and "SSA-IR with explicit checks, `store_ref`", and §6's "a v1 program is single-threaded, with one mutator" gains a collector thread, so the measurement and the proposal go to the operator before any code.
Where: requirements §6, §4.3, §4.5, §13 (the derived-pointers row); [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), rows `rt` and `gc`; [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `ir`, `codegen`, `abi`; [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2), rows "Concurrent GC with write barriers" and "NaN-boxing, precise roots, shadow stack"; `src/runtime/gc/`, `src/codegen/instructions.odin`; `bench/ts/trees.ts`, `bench/ts/objects.ts`.
After: T6.6.
Done: the measurement is recorded in the plan's risk item; for what the operator accepts, the corpora are green in all passes, under stress and ASan too, a gc test pins each new invariant the way stress mode pins the v1 ones, `trees` is measured before and after, and requirements §6 and the key blocks' text say what changed.

## Milestone 7: v2 waves (epics)

An actionable v2 task cannot be written before the v1 code exists. Each epic starts with the task "split per the row of the [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2) table". The agent reads its row and the code of the affected packages and proposes tasks for the board. The wave order is a recommendation. E7.1 and E7.11 moved to T6.7 and T6.8 on 2026-09-28 and took two of the §13 risks with them, the f64 gap and the derived pointers; the exact-type rule stays with E7.4. The other epics keep their numbers.

- [ ] E7.2 Classes, inheritance, `this`; user generics via monomorphization. Rows "Classes, inheritance...", "User generics...".
- [ ] E7.3 `try`, `catch`, `throw`. Row "`try`, `catch`, `throw`".
- [ ] E7.4 Full structural typing via fat pointers. Row "Full structural typing via fat pointers".
- [ ] E7.5 Index signatures, `Object.keys`, `for...in`, `obj[key]`, `Map`, `Set`; package `rt/table`. Row "Index signatures...".
- [ ] E7.6 Sugar: destructuring, spread, `?.`, `enum`, `export default`, getters and setters. Row "Destructuring, spread...".
- [ ] E7.7 `async` and `await`; package `rt/sched`. Row "`async` and `await`".
- [ ] E7.8 N codegen units and ThinLTO. Row "N codegen units and ThinLTO". `codegen.add_type_tables` and `add_roots` emit `tsnc_type_tables` and `tsnc_roots` into every unit's module today, which N units would define N times.
- [ ] E7.9 Cross-compiling for Linux from Windows; `wasm32-wasi`. Row "Cross-compilation and `wasm32-wasi`".
- [ ] E7.10 PDB and DWARF debug info. Row "Debug info".
- [ ] E7.12 `RegExp`, `bigint`, file I/O; hybrid Latin-1 and UTF-16. Rows "`RegExp`, `bigint`, file I/O", "Hybrid Latin-1 and UTF-16 storage".

## v1 critical path

T1.1 → T1.3 → T1.5 → T1.6 → T1.7 → T1.8 → T1.9 → T2.2 → T2.3 → T2.4 → T2.5 → T2.7 → T2.8 → T3.1 → T3.2 → T3.3 → T3.4 → T3.5 → T3.6 → T4.1 → T4.2 → T4.3 → T4.4 → T4.5 → T4.7 → T5.1 → T5.2 → T5.3 → T5.4 → T5.5 → T5.7 → T5.8 → T5.9 → T5.10 → T6.1 → T6.2.

Running in parallel with the critical path: T1.2 and T1.4 (after T1.1), T2.1 and T2.6, T4.6 (after T1.5), T5.6, T6.3. T5.11 to T5.17 run between T5.10 and T6.1: they change tests, the runner and comments, not what the compiler does. T6.4 to T6.8 come after T6.3 and before the v2 waves; T6.4 and T6.5 share no code and can run in parallel; T6.7 and T6.8 both follow T6.6 and both change `codegen`, so they run one after the other.
