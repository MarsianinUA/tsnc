# Task board: tsnc

Source: `architecture-plan-tsnc.md` (section "Milestones") and `REQUIREMENTS.md` v0.1. Updated: September 18, 2026.

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
   - runtime: `odin build src/runtime -build-mode:obj -out:dist/tsnc_rt-<target>.obj -vet -strict-style`;
   - runs: `odin run tests/runner -out:dist/runner.exe -- smoke | negative | diff`.
5. General done criterion for any task: `odin check` and `odin test` of the affected packages are green; no new package, mode flag, package-level state or import against the pipeline beyond the plan; every new diagnostic has a code in the `diag` registry and a hint; all text in English: comments, documentation, compiler messages; the agent makes no commits.
6. The agent's report to the operator at the end: what was done, how it was checked, what is left or what was blocked by the plan.

## Milestone 1: infrastructure and smoke test

Milestone goal: [Milestones](architecture-plan-tsnc.md#milestones), row 1. Requirements §4.2 (first smoke test), §10.

### [ ] T1.1 Repository skeleton `projects/tsnc`

What: copy `projects/odin-template`; create `src/`, `src/runtime/`, `src/llvm/`, `src/lib/`, `tests/`, `bench/`, `dist/`; `src/main.odin` parses flags through `core:flags` into an `Options` struct (commands `build`, `run`, `check`; `-out`, `-o`, `-emit-llvm`, `-emit-ir`, `-target`, `-j`) and answers "not implemented" with exit code 1; a README with the commands from the shared handoff kit; move `REQUIREMENTS.md`, `architecture-plan-tsnc.md`, `tasks-tsnc.md` into `docs/`, translated to English.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `main`; requirements §9 (CLI), §11 (repository structure).
After: none.
Done: `odin build src -out:dist/tsnc.exe -vet -strict-style` builds; `tsnc build x.ts` prints the parsed options and exits with code 1.

### [ ] T1.2 LLVM-C 20 bindings: `llvm` package

What: generate with odin-c-bindgen or write by hand a subset of LLVM-C 20: Core (context, module, types, builder, constants, functions, attributes, module verifier), Target and TargetMachine, PassBuilder (`LLVMRunPasses`), `LLVMParseCommandLineOptions`, printing a module to text. Names as in C. `foreign import` for `LLVM-C.dll` on Windows; on Linux and macOS the system LLVM 20 provides the library, since the Odin distribution does not ship it there.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `llvm`; [External boundaries](architecture-plan-tsnc.md#external-boundaries); [Precedents](architecture-plan-tsnc.md#precedents), the item on the new pass manager; requirements §4.2, §13 (bindings risk).
After: T1.1.
Done: `odin check src/llvm`; a test creates a context and a module, adds a function, prints the text, frees everything.

### [ ] T1.3 `abi` contract, v1 minimum

What: cell header, tags and the tagged value, string, array, closure and environment cells; type table format (size, kind of each slot, field names, array element kind); enum `Runtime_Proc` with a table of symbol names and signatures (in this milestone only string output and failure; the table grows in the runtime tasks); closure procedure type `proc "c"` with the environment as the first parameter; the name `tsnc_main`; runtime error codes; `#assert` on sizes (tagged 16 bytes, reference 8).
Where: [Contracts → ABI](architecture-plan-tsnc.md#abi-package-abi); [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `abi`; [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Compiler and runtime contract"; requirements §3.2-3.6, §4.3, §6.
After: T1.1.
Done: `odin check src/abi`; the package imports only `base`.

### [ ] T1.4 `target` package

What: enum `Target` (windows_amd64, linux_amd64, darwin_arm64, darwin_amd64; `wasm32_wasi` is declared but has no table rows), a table: LLVM triple, LLD flavor, link flags taken from `odin build -print-linker-flags` on each OS, runtime object name, pointer size; parsing of the `-target:` value.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `target`; [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Target platform"; requirements §9.
After: T1.1.
Done: tests for parsing target strings and for a non-empty table for each v1 target.

### [ ] T1.5 Runtime shell: `rt`, `console`, `fail`

What: `src/runtime`, package `rt`: `main` initializes the context, calls `tsnc_main`, exits the process; an export that prints a string cell (header followed by `u16` units) as UTF-8 through `core:io` regardless of the code page; `fail`: message to stderr and exit code 1; `context` setup on entry to each export (per-call scratch arena, `temp_allocator` reset, `assertion_failure_proc`).
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), rows `rt`, `console`, `fail`; [Contracts → Runtime exports](architecture-plan-tsnc.md#runtime-exports-package-rt); requirements §3.9, §4.3, §4.5.
After: T1.3.
Done: the runtime object builds on the host; `odin test tests/runtime/console` checks UTF-8 for Cyrillic and emoji.

### [ ] T1.6 `codegen`, minimum: hello world module to an object file

What: `init_global_options` (once, `-disable-lsr`); context, module and `TargetMachine` from `Target`; runtime function declarations from the `abi.Runtime_Proc` table; a static string cell in the data section with the `abi` layout; a `tsnc_main` function that calls string output; a pass pipeline by level (`default<O2>`, `default<O3>`, no optimization); output of the object file and the `.ll` text. The entry point already has the form `emit(..., Unit, Target, level, artifact kind, path)`; for now a built-in hello world stands in for the IR.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `codegen`; [Key decisions](architecture-plan-tsnc.md#key-decisions), rows "Codegen unit", "Target platform"; [External boundaries](architecture-plan-tsnc.md#external-boundaries); requirements §4.1 item 5, §4.2.
After: T1.2, T1.3, T1.4.
Done: the package test writes `dist/hello.obj` and `dist/hello.ll`; the module passes the LLVM verifier.

### [ ] T1.7 `link` package

What: run LLD (the distribution's `bin/lld-link.exe` on Windows, `ld.lld` and `ld64.lld` from the system LLVM on Linux and macOS) with the flavor and flags from `target`; inputs: program object, runtime object (found next to `tsnc.exe`, a parameter overrides the path), system libraries; LLD's stderr inside `Link_Error`.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `link`; [External boundaries](architecture-plan-tsnc.md#external-boundaries); requirements §4.1 item 6, §9.
After: T1.4, T1.5, T1.6.
Done: a test links `hello.obj` with the runtime object, runs the result, stdout equals the expected string, exit code 0.

### [ ] T1.8 Smoke test: `tests/runner smoke`

What: a `tests/runner` program (package `main`) with a `smoke` mode: `codegen` hello world, `link`, run, compare output. The same program later gets the `negative` (T2.9) and `diff` (T4.7) modes.
Where: [Package boundaries: tests and tools](architecture-plan-tsnc.md#package-boundaries-tests-and-tools); requirements §10 "Infrastructure smoke test".
After: T1.7.
Done: `odin run tests/runner -- smoke` is green on the host.

### [ ] T1.9 CI on four images

What: GitHub Actions: `windows-latest`, `ubuntu-latest`, `macos-latest`, `macos-26-intel`; install Odin nightly and LLVM 20 (Linux, macOS); build the compiler and the runtime object; `odin test` of all packages; smoke. T2.9, T4.7 and T5.10 extend the matrix.
Where: [Package boundaries: tests and tools](architecture-plan-tsnc.md#package-boundaries-tests-and-tools), row CI; requirements §9, §10, §13 (macOS only in CI).
After: T1.8.
Done: a green run on all four images.

## Milestone 2: frontend up to `bind`

Milestone goal: [Milestones](architecture-plan-tsnc.md#milestones), row 2.

### [ ] T2.1 `source`: file table and positions

What: `File_ID`, `Span` (file, start, end), file table (normalized path, text), conversion of an offset to line and column through a table of line breaks; choose the column unit (code points or UTF-16 units) in the detailed plan and record it in the `diag` registry as a format rule.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `source`; requirements §5 (diagnostic format).
After: T1.1.
Done: position conversion tests on files with `\r\n`, Cyrillic, empty lines.

### [ ] T2.2 `diag`: code registry and diagnostic as a value

What: an enum of codes of the form `T0001` with a table of text and hint; `Diagnostic` (code, span, arguments); sorting by (`File_ID`, offset, code); rendering `file:line:col: error[T0123]: text` plus a hint line; the first codes for syntax and the syntactic subset. New codes are added only here.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `diag`; [Contracts → Diagnostic](architecture-plan-tsnc.md#diagnostic-package-diag); [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rules 6 and 8; requirements §2.3, §5.
After: T2.1.
Done: rendering and sorting tests; a test that every code has non-empty text and hint.

### [ ] T2.3 `ast`: tree nodes and `Node_ID`

What: node shapes for the v1 subset (§2.2 "v1"), type syntax (union, arrays, object types, function types, literal types, `Array<T>`), `interface` and `type`, ESM import and export, `declare` and generic interfaces for the lib file; `Bad` nodes; dense `Node_ID` within a file; `File_AST` with a list of imports; traversal. Only data and traversal.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `ast`; [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rules 2 and 3; [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Shape of check facts"; [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may), the item on pointers or indices; requirements §4.1 item 2.
After: T2.1.
Done: `odin check src/ast`; a traversal test on a hand-built tree.

### [ ] T2.4 `parse.tokenize`: tokenizer

What: TS tokens for v1, number and string literals, template strings with nesting, a "line break before the token" flag for ASI, positions as `Span`; an unknown character or an unclosed literal produces a diagnostic with a code, and parsing continues.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `parse`, stage `tokenize`; [Key decisions](architecture-plan-tsnc.md#key-decisions), the alternative "`lex` as a separate package"; requirements §4.1 item 1.
After: T2.2, T2.3.
Done: tests: operators, numbers (`1e21`, `0x10`, fractional), strings with escapes, nested templates, ASI flags.

### [ ] T2.5 `parse.parse_tokens`: recursive descent

What: expressions with precedence, statements, declarations, type syntax, import and export, ASI per the specification; syntactic rules of the subset (`var`, `with`, `namespace`, decorators, `arguments`, `delete`, `eval`, `new Function`) as diagnostics with a hint, recovery through a `Bad` node and continuation; `parse_file` as `tokenize` plus `parse_tokens`.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `parse`; [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rule 8; requirements §2.2 "Never", §2.3, §4.1 item 2.
After: T2.4.
Done: tests for every v1 construct and every syntactic "never" rule (code, line, column); after an error the parser finds the next one.

### [ ] T2.6 Lib file `src/lib/lib.d.ts`

What: v1 declarations: `console`, `process` (`argv`, `exit`), `Math`, `Number`, `String` and the string methods from §2.2, `Array<T>` with methods including `map<U>`; only syntax that T2.5 supports; included through `#load`.
Where: [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Built-in types"; [Assumptions](architecture-plan-tsnc.md#assumptions), the item on `declare`; requirements §2.2 (standard library), §4.5 (`Math` bypasses the runtime).
After: T2.5.
Done: a test in `parse` parses the lib file with no diagnostics; the list of declarations matches §2.2.

### [ ] T2.7 `bind`: symbols, scopes, flow graph

What: the file's symbol table; scope tree (block-scoped `let` and `const`, functions, parameters); import and export tables by name; control flow graph for narrowing (branches, loops, assignments, in the style of tsc flow nodes); a top-level side effects flag; file-level diagnostics (redeclaration).
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `bind`; [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Name binding"; [Precedents](architecture-plan-tsnc.md#precedents), the item on tsc; requirements §4.1 item 3, §5 (narrowing), §7 (side effects).
After: T2.3.
Done: tests for scopes, closure capture, import and export tables, the flow graph for `if`, `switch` and loops, and the effects flag.

### [ ] T2.8 `driver` and `main`: `tsnc check` for syntax

What: reading the input file; the import closure loop (sequential for now): relative paths, `File_ID` in breadth-first order, the lib file as number zero; `parse_file` and `bind_file` per file in a task arena, written as a task procedure (the pool comes in T6.1); collecting diagnostics, sorting and rendering to stderr, exit code.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `driver`, `main`; [Interaction map](architecture-plan-tsnc.md#interaction-map), the "Determinism" paragraph; [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rules 4 and 5; requirements §7, §9.
After: T2.5, T2.6, T2.7.
Done: `tsnc check` on a multi-file example lists all syntax errors in a deterministic order; a missing import file produces a diagnostic at the import position.

### [ ] T2.9 `tests/runner negative`

What: the `negative` mode: for each `tests/negative/*.ts`, expectations from header comments (`// expect: T0123 3:5`), run `tsnc check`, compare codes and positions, list the mismatches; first corpus: the syntactic "never" rules; add to CI.
Where: [Package boundaries: tests and tools](architecture-plan-tsnc.md#package-boundaries-tests-and-tools); requirements §10 "Negative tests".
After: T2.8, T1.8.
Done: `odin run tests/runner -- negative` is green in CI.

## Milestone 3: `program` and `check`

Milestone goal: [Milestones](architecture-plan-tsnc.md#milestones), row 3.

### [ ] T3.1 `program`: frozen program and module graph

What: `Program` (file table, AST and `Bound_File` by `File_ID`, import edges, the lib `File_ID`); graph construction: topological order through `core:container/topological_sort`, strongly connected components, the diagnostic "cycle between modules with side effects"; `driver` builds `Program` after parsing.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `program`; [Contracts → Program](architecture-plan-tsnc.md#program-package-program); [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Program data umbrella"; requirements §7.
After: T2.8.
Done: tests: chain, diamond, a types-only cycle (allowed), a cycle with effects (error at the import position).

### [ ] T3.2 `check`, core: types, table, primitives and functions

What: TS types as a `union` with interning in the checker's table (`Type_ID`); primitives, literal types, `any`, the error type; typing of declarations and expressions (arithmetic, comparisons, logical, bitwise, `typeof`, ternary, template strings); functions and arrows: parameters, return type inferred from the body, functions as values, calls with argument checking; `Typed_File` with tables by `Node_ID`; entry point `check(^Program, partition, allocator)`.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `check`; [Contracts → Check_Result and Typed_File](architecture-plan-tsnc.md#check_result-and-typed_file-package-check); [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Parallel checkers"; [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rule 7; requirements §5, §3.1, §3.7.
After: T3.1.
Done: tests for type inference and mismatch diagnostics; `==` on different types produces an error with a hint about `===`.

### [ ] T3.3 `check`: objects, arrays, generics of built-in types

What: object literals and types, `interface` and `type`, optional and `readonly` fields, the exact-type rule with a hint; arrays: `T[]`, literals, element type inference, indexing, methods from lib through instantiation of `Array<T>`; contextual typing of arrow parameters; inferring `U` in `map<U>` from the function body; string methods through lib.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `check`; requirements §3.3, §3.6, §5 (contextual typing, instantiation), §2.2 (methods).
After: T3.2, T2.6.
Done: tests: `Point` and `Vec2` are compatible; `{x, y, z}` into `{x, y}` produces an error with a hint; `arr.map(x => x * 2)` infers `number[]`.

### [ ] T3.4 `check`: union and narrowing

What: canonical unions, `T | undefined` for optional ones; narrowing by `typeof`, by a literal field (`===`, `switch`), by `null` and `undefined`, by `!`; uses the flow graph from `bind`; the narrowed type goes into `Typed_File` for the identifier at the point of use; `as` rules (widening and narrowing of a union; `as any` and `as unknown as T` are forbidden).
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `check`; [Contracts → Check_Result and Typed_File](architecture-plan-tsnc.md#check_result-and-typed_file-package-check), invariants; requirements §2.2 (union and narrowing), §3.4, §3.8, §5.
After: T3.2.
Done: tests for each kind of narrowing and for errors outside narrowing; `as any` is rejected with a code.

### [ ] T3.5 `check`: modules, lib and semantic rules of the subset

What: resolution of `import` and `export` through `Program` and the `bind` tables, `import * as m`, unknown export; lib module symbols are visible everywhere; `declare` outside lib is rejected; the semantic remainder of the "never" rules (prototypes, `__proto__`, `Symbol`, changing an object's shape); control statements and `for...of` over arrays and strings; `console.log` with any number of arguments; import cycles of only types and functions are allowed.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `check`; [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rule 8; requirements §2.1-2.3, §7, §3.9.
After: T3.3, T3.4.
Done: negative tests for each semantic rule; a multi-file example with a re-export passes.

### [ ] T3.6 `driver`: full `tsnc check`, v1 negative test corpus

What: `check` with one partition after `program`; collecting `Check_Result`; the policy "reach `lower` only with no errors"; extend the `tests/negative` corpus to one program for each subset rule and type rule.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `driver`; [Milestones](architecture-plan-tsnc.md#milestones), row 3; requirements §2.3, §10.
After: T3.5, T2.9.
Done: `tsnc check` finds all corpus errors in one pass; `runner negative` is green in CI.

## Milestone 4: vertical slice to an executable

Milestone goal: [Milestones](architecture-plan-tsnc.md#milestones), row 4.

### [ ] T4.1 `ir`: data and builder

What: IR types (`Void`, `F64`, `Bool`, `Tagged`, `Ref(Layout)`, `Str`, `Closure`); layouts interned by canonical key (`Layout_ID`); instructions as a closed `union` (arithmetic, comparisons, branches, `phi`, `alloc`, fields, `store_ref`, elements with `bounds_check`, `tag_test`, `box` and `unbox`, `call`, `call_closure`, `call_runtime`, `intrinsic`, `fail`, string constant); `Func` with blocks in flat arrays and `distinct` indices; `Program_IR`; builder; a span on every instruction.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `ir`; [Contracts → Program_IR](architecture-plan-tsnc.md#program_ir-package-ir); [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Shape of our own IR"; requirements §4.1 item 4, §6.
After: T1.3.
Done: `odin check src/ir`; a test builds a function with the builder.

### [ ] T4.2 `ir`: printer and verifier

What: a text dump for `-emit-ir` (stable, line-based); verifier: definition before use, a terminator in every block, consistent operand types, `store_ref` only into reference slots.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `ir`; [What must not change and what may](architecture-plan-tsnc.md#what-must-not-change-and-what-may), the item on the dump format; requirements §9 (`-emit-ir`).
After: T4.1.
Done: the verifier catches a block without a terminator and a use before definition; the dump is deterministic.

### [ ] T4.3 `lower`: scalar slice

What: `lower(^Program, []Check_Result, allocator)`: numbers, booleans, `null`, `undefined`, string literals as pool constants; functions without captures, and calls; control flow (`if`, `switch`, loops, `break`, `continue`, ternary, `&&`, `||`, `??` through `phi`), `return`; top-level module code as init functions in `Program` order, `tsnc_main`; a "lib name → strategy" table for `console.log` and `console.error`, `process.exit`, `Math` (intrinsics and libm; `round`, `max`, `min` go to the runtime); mapping a TS type to an IR type, without objects.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `lower`; [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rule 7; [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Built-in types"; requirements §3.1, §3.5, §4.5 (`Math`), §7.
After: T4.2, T3.6.
Done: the IR dump for programs with loops and `switch` passes the verifier; a test checks that the strategy table covers all names from the lib file.

### [ ] T4.4 `codegen` from IR

What: mapping of IR types to LLVM (tagged as a struct of two 64-bit words, references as pointers), instructions one to one, `phi`; runtime function declarations from `abi`; `llvm.*.f64` intrinsics and libm; static string cells; pass pipeline by level; `-disable-lsr`; object and `.ll`; `Unit` as a slice of functions; remove the hello world stub from T1.6.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `codegen`; [Interaction map](architecture-plan-tsnc.md#interaction-map); requirements §4.1 item 5, §4.2, §6 (LSR).
After: T4.3.
Done: a test builds an object for the IR from T4.3; the module passes the LLVM verifier.

### [ ] T4.5 `driver`: full pipeline and commands

What: `lower`, `codegen`, `link` in a chain; `tsnc build`, `tsnc run` (runs the program with inherited stdio and passes on its exit code), `-out:`, `-o:none`, `-emit-llvm`, `-emit-ir`, `-target:`; write the artifact to a temporary file and rename it; an arena per phase.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), rows `driver`, `main`; [Simplicity and robustness](architecture-plan-tsnc.md#simplicity-and-robustness), the item on atomicity; requirements §9.
After: T4.4, T1.7.
Done: `tsnc run` on a program of numbers and loops prints the result; `-emit-ir` and `-emit-llvm` write files.

### [ ] T4.6 `rt/num` and primitive output in `console`

What: `num`: conversion per `Number::toString` (§3.1) on top of `core:strconv` (shortest representation, thresholds `1e21` and `1e-7`, `-0`, `NaN`, `Infinity`), `parseFloat` per the `ToNumber` grammar, `toFixed`; `console` prints numbers, booleans, `null`, `undefined`, strings, several arguments separated by spaces; `Runtime_Proc` exports; `Math.round`, `Math.max`, `Math.min`.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), rows `num`, `console`; requirements §3.1, §3.9, §4.5 (table, row "Numbers to string and back").
After: T1.5.
Done: `num` tests against a table of values taken from Node (`0.1 + 0.2`, `1e21`, `1e-7`, `-0`, `2 ** 53`); primitive output matches Node byte for byte.

### [ ] T4.7 `tests/runner diff` and the first corpus

What: the `diff` mode: gate `tsc --noEmit --strict` (`tests/package.json`, TypeScript as a dev dependency), reference `node test.ts`, `tsnc build`, run, compare stdout, stderr and exit code byte for byte; corpus: arithmetic, comparisons, bitwise, `switch`, loops, functions, template strings, `Math`, `process.exit`; add to CI.
Where: [Package boundaries: tests and tools](architecture-plan-tsnc.md#package-boundaries-tests-and-tools); requirements §10 "Differential tests", "Gate".
After: T4.5, T4.6, T2.9.
Done: the corpus is green on three OSes in CI.

## Milestone 5: full runtime, objects, arrays, closures, union

Milestone goal: [Milestones](architecture-plan-tsnc.md#milestones), row 5.

### [ ] T5.1 `gc`: size-class allocator and type tables

What: reserving and committing pages through `core:mem/virtual`; size classes; an object start map (a pointer into a cell finds its owner); allocation with a header by type table ID; registration of the type tables that the compiler places in the object file (a symbol with the table, read at startup); heap integrity check; no collection yet; the only state is `Heap`, initialized in `rt.main`.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `gc`; [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Runtime memory"; requirements §6 (consequences of conservative scanning), §4.5 (row "GC heap pages").
After: T1.5.
Done: tests: allocations of different classes, owner lookup by an interior pointer, integrity check on a live heap.

### [ ] T5.2 `gc`: mark-sweep, conservative stack, precise heap

What: an assembly stub per platform (Windows x64, SysV x64, arm64) to spill callee-saved registers and capture the stack bounds; conservative stack scan; precise heap scan by type tables (pointer slots and tagged slots); marking; sweeping into per-class free lists; a trigger threshold; stress mode (a collection on every allocation plus an integrity check) turned on by an environment variable.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `gc`; [Precedents](architecture-plan-tsnc.md#precedents), the item on Go GC, Oilpan, bdwgc; requirements §6, §10 "GC stress mode".
After: T5.1.
Done: tests: an allocation loop with a live set on the stack loses no objects; garbage gets freed; stress mode is green.

### [ ] T5.3 `str`: UTF-16 strings and methods

What: string cell in the heap; creation from UTF-8 and UTF-16; `string16` into the cell; `length`, `charCodeAt`, indexing, `slice`, `indexOf`, `includes`, `split`, `trim`, `toUpperCase` and `toLowerCase` by full Unicode rules (`ß` becomes `SS`), `startsWith`, `endsWith`, concatenation, comparison by 16-bit units, `===`; exports in `Runtime_Proc`.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `str`; requirements §3.2, §2.2 (methods), §4.5 (row "Strings"), §13 (`string16` from nightly).
After: T5.1.
Done: tests with Cyrillic and emoji against Node values (`length`, `slice`, `charCodeAt`).

### [ ] T5.4 `value`: tagged values

What: `typeof`, strict equality by tag (primitives by value, strings by content, references by address), truthiness, conversion to string by tag; exports.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `value`; requirements §3.4, §3.7.
After: T5.3.
Done: tests for all tags, including `NaN !== NaN` and `-0 === 0`.

### [ ] T5.5 `arr`: arrays

What: array cell with a buffer in the heap (unboxed elements by element kind); amortized growth; `push`, `pop`, `slice`, `indexOf`, `includes`, `join`; sorting through `slice.stable_sort_by` over a temporary copy with a closure comparator per the `abi` convention (`undefined` goes last); exports.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `arr`; [Interaction map](architecture-plan-tsnc.md#interaction-map), row "`rt` (array sort) to generated code"; requirements §3.6, §4.5 (row "Array sorting").
After: T5.4.
Done: tests, including a call to a stub comparator through the calling convention.

### [ ] T5.6 Full `console` and `process`

What: Node format for objects and arrays in simple cases (`[ 1, 2, 3 ]`, `{ a: 1, b: 'x' }`) through type tables with field names, nesting; `console.error`; `process.argv` as an array of strings from the OS arguments (UTF-8 to UTF-16); `process.exit`.
Where: [Package boundaries: runtime](architecture-plan-tsnc.md#package-boundaries-runtime), row `console`; requirements §3.9, §2.2 (standard library), §13 (Node format risk).
After: T5.5.
Done: output tests against Node values on a set of simple values.

### [ ] T5.7 `lower`: objects and arrays

What: canonical layout key from a TS type (fields by name, optional ones as tagged slots, recursive types per the plan's assumption); GC type tables in `Program_IR` and their emission in `codegen`; `alloc` and field access by offset; `store_ref` for reference slots; arrays: literals, indexing with `bounds_check`, a write at `i === length` as `push`, `length`; `map`, `filter`, `forEach`, `reduce` as inlined loops, the rest as runtime calls; `for...of`.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `lower`; [Contracts → Program_IR](architecture-plan-tsnc.md#program_ir-package-ir), invariants; [Assumptions](architecture-plan-tsnc.md#assumptions), the item on recursive types; requirements §3.3, §3.6, §3.8, §4.5 (what the compiler emits).
After: T4.5, T5.5.
Done: diff tests for objects and arrays pass in normal and stress mode.

### [ ] T5.8 `lower`: closures

What: a function value as a pair (code, environment); the environment as a heap cell with a type table; captured mutable variables in heap cells, immutable ones by copy; a new `let` binding per iteration; indirect call through `call_closure`; passing closures to the runtime (sorting).
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `lower`; requirements §3.5, §6 (closures in the heap).
After: T5.7.
Done: diff tests: counter closures, closures in a loop capture different `i`, sorting with a comparator.

### [ ] T5.9 `lower`: union, `any`, optional fields, §3.8 checks

What: the tagged representation; `box` on assignment into a union, `unbox` after narrowing per `Typed_File`; `tag_test` from `typeof` conditions, literal field conditions, `switch`, `null`; `x!` and a narrowing `as` as a tag check with `fail`; `fail` with file, line and column as constants; `undefined` for missing optional fields.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `lower`; requirements §3.4, §3.8, §2.2 (union and narrowing).
After: T5.8.
Done: diff tests for discriminated unions and `typeof` branches; a failed `x!` produces the expected stderr and exit code 1.

### [ ] T5.10 ASan, stress mode in CI, full v1 corpus

What: a runtime build with `-sanitize:address` for a separate run; `runner diff` in GC stress mode; corpus: one program for each §2.2 v1 construct plus programs with allocations and closures in a loop; a `bench/` starter with hello world (startup time, exe size).
Where: [Milestones](architecture-plan-tsnc.md#milestones), row 5; [Package boundaries: tests and tools](architecture-plan-tsnc.md#package-boundaries-tests-and-tools); requirements §10 (v1 acceptance criterion, ASan, stress, benchmarks).
After: T5.9, T5.2.
Done: the whole corpus is green on three OSes in normal, stress and ASan mode.

## Milestone 6: parallelism and determinism

Milestone goal: [Milestones](architecture-plan-tsnc.md#milestones), row 6.

### [ ] T6.1 `driver`: thread pool for parsing

What: `core:thread.Pool`; a task per file with its own arena (`pool_add_task` with the task allocator); the import closure loop in waves (all known files in parallel, then the new ones); `File_ID` in breadth-first order regardless of the order in which tasks finish; `-j:N`, defaulting to the number of cores; `codegen.init_global_options` before the pool.
Where: [Package boundaries: compiler](architecture-plan-tsnc.md#package-boundaries-compiler), row `driver`; [Philosophy](architecture-plan-tsnc.md#philosophy-a-pipeline-of-frozen-layers), rules 4 and 5; [Interaction map](architecture-plan-tsnc.md#interaction-map), the "Determinism" paragraph; requirements §8.
After: T5.10.
Done: a test: the same project at `-j:1` and `-j:8` gives the same `File_ID` values and the same diagnostic order.

### [ ] T6.2 `driver`: N checkers over partitions

What: split into contiguous `File_ID` ranges balanced by size; a task per partition with arenas; `lower` reads each file's facts from its checker's table; diagnostic sorting; determinism test: byte-identical `-emit-ir`, `-emit-llvm` and executable at `-j:1` and `-j:8`.
Where: [Key decisions](architecture-plan-tsnc.md#key-decisions), row "Parallel checkers"; [Contracts → Check_Result and Typed_File](architecture-plan-tsnc.md#check_result-and-typed_file-package-check), invariants; requirements §8, §11.
After: T6.1.
Done: the determinism test runs in CI; the v1 acceptance criterion is fully met.

### [ ] T6.3 Benchmarks

What: `bench/`: numeric loops, strings, arrays of objects, closures, allocations against Node and Go; startup time and exe size; compile time at `-j:1` and `-j:N` (the cost of duplicated checker work); results in `bench/RESULTS.md` by version.
Where: [Risks and open questions](architecture-plan-tsnc.md#risks-and-open-questions), the item on private tables; requirements §10 "Benchmarks", §11.
After: T6.2.
Done: v1 results are recorded.

## Milestone 7: v2 waves (epics)

An actionable v2 task cannot be written before the v1 code exists. Each epic starts with the task "split per the row of the [Provisions for v2](architecture-plan-tsnc.md#provisions-for-v2) table". The agent reads its row and the code of the affected packages and proposes tasks for the board. The wave order is a recommendation; the first two waves remove the main risks of §13.

- [ ] E7.1 `opt`: integer narrowing, escape analysis, bounds check elimination. Rows "Integer optimization of `number`", "Escape analysis and bounds check elimination"; requirements §3.1 (v2), §4.1 item 4.
- [ ] E7.2 Classes, inheritance, `this`; user generics via monomorphization. Rows "Classes, inheritance...", "User generics...".
- [ ] E7.3 `try`, `catch`, `throw`. Row "`try`, `catch`, `throw`".
- [ ] E7.4 Full structural typing via fat pointers. Row "Full structural typing via fat pointers".
- [ ] E7.5 Index signatures, `Object.keys`, `for...in`, `obj[key]`, `Map`, `Set`; package `rt/table`. Row "Index signatures...".
- [ ] E7.6 Sugar: destructuring, spread, `?.`, `enum`, `export default`, getters and setters. Row "Destructuring, spread...".
- [ ] E7.7 `async` and `await`; package `rt/sched`. Row "`async` and `await`".
- [ ] E7.8 N codegen units and ThinLTO. Row "N codegen units and ThinLTO".
- [ ] E7.9 Cross-compiling for Linux from Windows; `wasm32-wasi`. Row "Cross-compilation and `wasm32-wasi`".
- [ ] E7.10 PDB and DWARF debug info. Row "Debug info".
- [ ] E7.11 Concurrent GC with write barriers; NaN-boxing and precise roots, depending on benchmark results. Rows "Concurrent GC with write barriers", "NaN-boxing, precise roots, shadow stack".
- [ ] E7.12 `RegExp`, `bigint`, file I/O; hybrid Latin-1 and UTF-16. Rows "`RegExp`, `bigint`, file I/O", "Hybrid Latin-1 and UTF-16 storage".

## v1 critical path

T1.1 → T1.3 → T1.5 → T1.6 → T1.7 → T1.8 → T1.9 → T2.2 → T2.3 → T2.4 → T2.5 → T2.7 → T2.8 → T3.1 → T3.2 → T3.3 → T3.4 → T3.5 → T3.6 → T4.1 → T4.2 → T4.3 → T4.4 → T4.5 → T4.7 → T5.1 → T5.2 → T5.3 → T5.4 → T5.5 → T5.7 → T5.8 → T5.9 → T5.10 → T6.1 → T6.2.

Running in parallel with the critical path: T1.2 and T1.4 (after T1.1), T2.1 and T2.6, T4.6 (after T1.5), T5.6, T6.3.
