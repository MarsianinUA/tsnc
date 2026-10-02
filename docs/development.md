# Development

How to build tsnc from source, run its tests and find your way around the repository.

## Commands

Run from the repository root. After cloning, create the output directory once with `mkdir dist`. Odin does not create the `-out:` directory itself, and without it the build fails with `LNK1104`. The directory is not in git.

```sh
# everything CI runs, on this machine: one line per step, the output of each in dist/all.log
tests/all.sh

# compiler
odin build src -out:dist/tsnc.exe -o:speed -vet -strict-style

# debug build of the compiler, then run it with arguments
odin run src -out:dist/tsnc-debug.exe -debug -vet -strict-style -- build main.ts

# type-check a library package (no `main`) without code generation
odin check src/<package> -no-entry-point -vet -strict-style

# package tests: unit tests of src/<package> live in tests/<package>/
# (the link and driver tests link a real program, so build the runtime object first)
odin test tests/<package> -out:dist/<package>-tests.exe -vet -strict-style

# runtime subpackage tests: src/runtime/<package> is tested in tests/runtime/<package>/
odin test tests/runtime/<package> -out:dist/runtime-<package>-tests.exe -vet -strict-style

# runtime object; without -use-single-module Odin writes one .obj per package
odin build src/runtime -build-mode:obj -use-single-module -o:speed -out:dist/tsnc_rt-<target>.obj -vet -strict-style

# the same runtime with AddressSanitizer, for `tsnc build -sanitize:address`
odin build src/runtime -build-mode:obj -use-single-module -o:speed -sanitize:address -out:dist/tsnc_rt-<target>-asan.obj -vet -strict-style

# test runs: unit runs `odin test` on every package under tests/, smoke links against the runtime
# object in dist/, and the others run dist/tsnc.exe, so build both first. A mode runs as many
# programs at a time as the machine has cores; -j:1 runs them one by one
odin build tests/runner -out:dist/runner.exe -vet -strict-style
dist/runner.exe unit
dist/runner.exe smoke
dist/runner.exe negative
dist/runner.exe diff
dist/runner.exe expect

# diff and expect need Node 24 and TypeScript, installed once from tests/diff/package.json
npm ci --prefix tests/diff
```

`-vet -strict-style` is part of every build, so there is no separate linter. An unused variable, a stray semicolon or spaces instead of tabs fail the build.

## LLVM

The compiler calls LLVM 20 through its C API (package `src/llvm`).

- Windows: `LLVM-C.dll` ships with Odin next to `odin.exe`. That directory must be on `PATH` when you run `tsnc.exe`, the test runner or the `llvm`, `codegen`, `link` and `driver` package tests. `driver` is on that list because it generates code: `tsnc build` goes through `codegen`, and `tsnc check` links the same binary. The import library is in the repository: `src/llvm/windows/LLVM-C.lib`.
- Linux: `sudo apt install llvm-20-dev` (Ubuntu 24.04 and later have it; elsewhere apt.llvm.org). The bindings link `libLLVM-20.so`, which the package puts on the default library path.
- macOS: `brew install llvm@20`. Homebrew keeps it off the default library path, so `src/llvm` gives the linker its directory: `/opt/homebrew/opt/llvm@20/lib` on Apple silicon, `/usr/local/opt/llvm@20/lib` on Intel. For LLVM 20 installed elsewhere, add `-extra-linker-flags:-L<dir>` to `odin build`, `odin test` and `odin run`.

On Linux and macOS the bindings link `LLVM-20` by name, so a machine without LLVM 20 fails at link time instead of picking up another version. Linking programs there goes through the system C compiler (`cc`), which Odin needs anyway.

## Linking

On Windows tsnc runs `bin/lld-link.exe` from the Odin that built it and needs what Odin needs: Visual Studio or Build Tools with the C++ x64 tools, and the Windows 10 or 11 SDK. It finds them the way Odin does, so the Developer Command Prompt is not required: the SDK through the registry, Visual Studio through `vswhere.exe`. On Linux and macOS it runs `cc`.

The runtime object `tsnc_rt-<target>.obj` must lie next to `tsnc.exe`. The runtime object command under [Commands](#commands) puts it there.

v1 builds a program for the machine it runs on. `-target:` for another platform still writes `-emit-llvm` and `-emit-ir`, but linking one needs that platform's libraries, which is v2 work.

The compiler CLI follows Odin. [Usage](../README.md#usage) in the README shows the everyday commands, and [requirements, section 9](REQUIREMENTS.md#9-platforms-cli-artifacts) has the full list.

Without `-out:` the artifact is named after the entry file, in the current directory: `tsnc build src/main.ts` writes `main.exe` on Windows and `main` elsewhere, `-emit-llvm` writes `main.ll` and `-emit-ir` writes `main.ir`. `tsnc run` builds the file `tsnc build` would and leaves it there; its exit code is the program's own.

`-emit-ir` writes the IR codegen gets: at `-o:none` the IR lower made, at `-o:speed` and `-o:aggressive` the IR `opt` made of it. A diff of the two dumps of one program shows what `opt` did.

## Negative tests

`tests/negative/` holds programs that must not compile, at least one for every code of the `diag` registry. `tests/runner negative` builds each one with `tsnc build` and compares the diagnostics it prints with the ones its header names:

```ts
// A module gives out only what it exports. The message stands at the specifier, ...
// expect: T4009 13:10 "module `./modules/values.ts` does not export `missing`"
// expect: T4009 modules/relay-nowhere.ts:4:10
```

The header is the run of comment and blank lines at the top of the file. An `// expect:` line names one diagnostic: the code, then the line and column where it starts. Both are 1-based, and the column counts UTF-16 code units, as tsnc prints it. A path in front of the line, relative to `tests/negative`, puts the diagnostic in a module the program imports. A quoted text at the end has to occur in the message or in its hint. It runs to the last `"` of the line, so it may hold quotes of its own. Other comments are prose.

The expectations are the whole list. They are compared one for one in print order: the program first, then its modules in the order the imports reach them, each by position. An extra diagnostic fails the program just as a missing one does, and so does a header that expects nothing or an `// expect:` line the runner cannot read. The build has to exit with code 1 and print nothing to stdout. Each program is built at `-j:1` and at `-j:8`, and the two builds must print the same bytes: one checker over the program and one per partition find the same mistakes.

`tsnc build` stops before lower when check reported anything. So a program that pins a code lower reports, T2027 or the T2029 of an `any` that would become a function, has to pass check.

`tests/negative/modules/` holds the modules the programs import, and they are never run on their own. A module that carries a mistake is imported by the one program that expects it, since every program that imported it would get the diagnostic too.

To write a program, put `// expect: T0000 0:0` placeholders in the header first, because the number of header lines moves every position below it. Work out each position from the source, then compare it with what `dist/tsnc.exe build tests/negative/<name>.ts` prints. Keep in mind:

- A mistake that runs to the end of the file, such as an unclosed block, stands last. Its position is the line after the last one, column 1, since every program ends with a line break.
- The parser reports one syntax error per line, so a program about syntax puts each mistake on a line of its own.

## Differential tests

`tests/diff/src/` holds whole programs, one per construct. `tests/runner diff` runs each under `node`, compiles the same file with `tsnc build` at `-o:none` and at `-o:speed`, runs both, once as they are and once under [GC stress](#gc-stress-mode), and compares stdout, stderr and the exit code byte for byte. Nothing is stored as an expected output: the expectation is what Node prints today.

Two tools are needed, and neither takes any part in a build. Node 24 runs a `.ts` file directly, which is what makes it a reference. TypeScript is the gate, so that a corpus program is TypeScript the real compiler accepts under `--strict` and not merely something tsnc happens to swallow. Both are dev dependencies of `tests/diff/package.json`:

```sh
npm ci --prefix tests/diff
```

`tests/diff/` is laid out as the npm project it is: the manifests at the top, `node_modules/` beside them, the programs under `src/`. They sit above the programs rather than elsewhere in `tests/`, because Node reads `"type": "module"` from the nearest `package.json` and it has to be an ancestor of the programs for an import in one of them to run. `tests/diff/node_modules/` is not in git; `tests/diff/package-lock.json` is, so every machine installs the same compiler. `tests/diff/tsconfig.json` says what the gate compiles and why each of its options is there.

A program in the corpus stays inside the part of the subset that is lowered, since one that does not compile is a failure rather than a skip. `tests/diff/src/modules/` holds modules that other programs import and that are never run on their own.

A new case goes into an existing program on its topic where one exists: a program costs about 0.45 s per pass, and CI runs the corpus several times. When you write one, keep in mind:

- The gate refuses some things tsnc accepts: a type imported without `import type`, a specifier without `.ts`, `===` between two literal types that cannot meet, and an operand that is truthy by its spelling alone, such as `!"a"` (TS2872). Pass such operands through parameters.
- A type the program means to pin goes on an annotated binding, `const early: "a" | "b" = v`, so that the build fails when check answers another type. A `let` given a wider value later pins that an inferred type widened.
- A program that prints must not end in `process.exit`: on macOS Node can lose the output written before it. Keep an exit path on a branch that never runs, and an exit code in 65..125, which `exit.ts` explains.
- The runtime calls a sort comparator in another order than V8 does, so a comparator neither prints nor counts, and one that changes the array does it on its first call only.

A program's header may hold two lines, each at most once and in either order, and the runner applies both to the Node run and to the compiled one. `// env:` sets environment variables on top of the runner's own environment:

```ts
// env: FORCE_COLOR=1 NO_COLOR= NODE_DISABLE_COLORS=
```

`tests/diff/src/colors.ts` does this to see colors in the output the runner reads, which is no terminal. The two empty values keep Node from warning that they are ignored, should the machine set them.

`// args:` passes command line arguments after the program. They are split on whitespace, with no quoting:

```ts
// args: one two --flag=x
```

`tests/diff/src/process-argv.ts` reads them from `process.argv`, a Cyrillic word and a character outside the BMP among them. It prints nothing from the first two entries, the executable and the script, since those differ between Node and the build.

## Expected-output tests

Requirements 3.8 turns some things Node accepts into runtime errors: a failed `x!` or `as`, a read before initialization, `reduce` of an empty array, an index out of range. The runtime adds its own: a conversion tsnc does not make, such as `%s` of a function, and a range Node throws a `RangeError` for, such as `process.exit(1.5)`. A compiled program writes one line to stderr and exits with code 1, where Node answers `undefined` or throws, so Node cannot be the reference. `tests/expect/` holds one program per such failure path, and `tests/runner expect` compares each with the output its header states:

```ts
// `x!` on a value that turns out undefined: the program prints what it wrote before the check,
// then fails at the start of `x!` with exit code 1 (requirements 3.8), where Node prints undefined.
// stdout: 4
// stderr: error: non-null assertion failed at tests/expect/non-null.ts:8:41
// exit: 1
```

The header is the run of comment and blank lines at the top of the file. Each `// stdout:` or `// stderr:` line is one line of that stream, in order, and a bare `// stdout:` is an empty line. A stream the header gives no line must stay empty, and `// exit:` appears exactly once and names 0, 1 or a code in 65..125: the others are also the number of a signal, and only the line on stderr tells 1 apart. Other comments are prose. A line that names one of the three keys but is spelled another way fails the program instead of being read as prose.

The runner builds each program by its path relative to the repository root, so the location in the message reads the same on every OS. The rest works as in `diff`: the tsc gate (`tests/diff/tsconfig.json` includes `tests/expect/*.ts`, so a program imports nothing), builds at `-o:none` and `-o:speed`, `-sanitize:address` when given, and a second run of each build under GC stress.

One failure has no program: building a string past the longest one Node makes takes more than 1 GB under AddressSanitizer and GC stress (1.16 GB measured), so `tests/runtime/str` checks the limit itself (`str.length_fits`) and the call that fails is one line.

Node never runs these programs, but their prose says what Node does instead, and `node tests/expect/<name>.ts` shows it. Work out the line and column of a new program's failure from the source, the start of the expression that fails, and then check the build against them rather than copying what it printed.

## GC stress mode

A compiled program runs its collector in stress mode when the environment variable `TSNC_GC_STRESS` is `1`, with no rebuild. It then collects before every allocation and checks the whole heap after every collection. A broken heap ends the program with exit code 1 and the address of the cell, page or free list where the check stopped:

```
error: internal error: heap check failed: dangling reference: 0x1f2c0010040
```

The runtime reads the variable once, at startup. Every check walks the whole heap, so a program that allocates a lot runs far slower in this mode.

The runner runs every build of the differential and the expected-output corpora twice, the second time with the variable set; Node and tsc never see it. A failure in that run names it: `-o:none under GC stress`.

Three programs of the corpus exist for the collector: `gc-objects.ts`, `gc-closures.ts` and `gc-large.ts` allocate enough to collect at least three times in the normal mode, where the first collection waits for 4 MiB and each later one for the heap to hold four times what the last one kept: they collect 3, 3 and 5 times. Each builds its bytes out of few allocations, long strings by doubling and whole arrays, so that under stress, where every allocation collects and checks the heap, a build still runs in about two seconds.

## GC statistics

A compiled program prints the collector's counts to stderr at exit when the environment variable `TSNC_GC_STATS` is `1`, with no rebuild, the way `GODEBUG=gctrace=1` does in Go and `--trace-gc` in Node. It prints one line for the whole run:

```
gc: 109 collections, 293.5 ms marking, 78.9 ms sweeping, 5.4 ms longest pause, 29447519 cells, 898.6 MB allocated, 10.6 MB live, 23.3 MB heap
```

| field | meaning |
| --- | --- |
| collections | how many times the collector ran |
| marking | time spent marking: the stack, the roots and the cells they reach |
| sweeping | time spent sweeping |
| longest pause | the longest single collection, marking and sweeping |
| cells | how many cells the program allocated, those generated code takes off a free list itself included |
| allocated | bytes of the slots and page runs those cells took |
| live | bytes the last collection kept, 0 when none ran |
| heap | bytes of the heap's pages; the heap never gives a page back, so this is its peak |

A megabyte is 2^20 bytes, and every tenth is cut, not rounded. The line comes when `main` returns and at `process.exit`. A program that fails prints its error and no line. Under stress mode the heap checks are not counted as marking or sweeping.

The counts are always kept, since an add per allocation and three clock reads per collection cost less than asking whether anyone wants them. The variable is read only at exit. `bench/bench.sh -gc` sets it and prints the counts of each program as a table.

## AddressSanitizer

`tsnc build -sanitize:address` and `tsnc run -sanitize:address` link the runtime built with AddressSanitizer, `tsnc_rt-<target>-asan.obj` next to `tsnc.exe`, which the second runtime command under [Commands](#commands) builds. Only the runtime is instrumented; the code tsnc generates is not.

In that build the collector tells ASan which bytes of its heap a program may touch: the cells in use and the first 16 bytes of each free slot, which hold its free list link. It poisons the rest, as Go's sweep does, so a runtime procedure that reads past the end of a cell or into the body of a freed one stops with ASan's report. A freed cell's first 16 bytes stay open, so a use after free that touches only a length or a header goes unnoticed.

ASan's fake stack is off. With it, every local whose address is taken moves to memory of ASan's own, the stack base the runtime hands the collector among them, and the stack scan would read past the real stack. The runtime answers `detect_stack_use_after_return=0` from `__asan_default_options`; `ASAN_OPTIONS` still overrides it. The gc unit tests have no runtime around them, so they need the variable:

```sh
ASAN_OPTIONS=detect_stack_use_after_return=0 odin test tests/runtime/gc -out:dist/runtime-gc-asan-tests.exe -vet -strict-style -sanitize:address -define:TSNC_EXPECT_ASAN=true
dist/runner.exe diff -sanitize:address
```

The define makes the first command fail if the build lost the sanitizer, where every ASan test would pass with nothing checked. The second command runs the differential corpus against the ASan runtime. The runner runs an ASan build in stress mode alone, where every allocation collects, so each cell is poisoned the moment it dies. CI runs both, and the expected-output corpus the way the second one runs.

`-sanitize:address` works on Windows and Linux. On macOS tsnc refuses it before linking anything, since the link would fail: `cc` is Xcode's clang, whose ASan runtime names its version check after Apple's clang, while the runtime object is instrumented by LLVM 20 and asks for `___asan_version_mismatch_check_v8`. Linking through the clang of Homebrew's `llvm@20` instead was tried in CI: the program died with SIGILL on the Intel image and hung on arm64 macOS 26, as [llvm-project issue 200447](https://github.com/llvm/llvm-project/issues/200447) reports for a one-line C program. So CI builds and runs ASan on Windows and Linux only, the way CPython runs ASan on Linux only and `go build -asan` exists only on Linux. The poisoning is the same code on every OS.


## Benchmarks

`bench/ts/` holds the programs of requirements 10: `mandelbrot` and `collatz` (numeric loops), `sieve` (a `boolean[]`), `chars` and `strings` (a scan by `s[i]` and the string methods), `objects` (an array of records sorted and filtered), `closures`, `trees` (binary-trees, for the collector) and `hello`. Each has a Go twin in `bench/go/<name>/main.go`. The twins run the same algorithm on the same data, in the types a Go programmer would pick: `int` where a value is always an integer, byte indexing for ASCII text, a slice of structs for records.

`bench/bench.sh`, or `bench\bench` in the Windows shells, runs `bench/runner` from the repository root, wherever it is called from. The runner needs Node and Go on `PATH`. scriptc and Bun are optional, and `npm install -g scriptc bun` installs both. On Windows scriptc links through Zig 0.16, which `winget install zig.zig` puts on `PATH`. npm puts only `.cmd` shims there, which the runner cannot start, so it runs the `.exe` from the package in `npm root -g`.

```sh
bench/bench.sh
bench/bench.sh chars strings
bench/bench.sh -against:base trees
```

The names pick benchmarks: a program, `hello` or `compile`. With no names, everything runs, which takes about four minutes.

Before any run the runner checks that every program has both `bench/ts/<name>.ts` and `bench/go/<name>/main.go`, and that neither directory holds a program missing from `PROGRAMS` in `bench/runner/programs.odin`. So adding a benchmark means two files and one line. Then it builds `dist/tsnc.exe` and the runtime object with the commands above, but only when a file in `src/` is newer than they are.

| flag | effect |
| --- | --- |
| `-runs:N` | timed runs of a program, 5 by default; hello always runs 20 |
| `-o:none`, `-o:aggressive` | the level of `tsnc build`, `speed` by default |
| `-sanitize:address` | links the runtime built with AddressSanitizer, and builds that runtime too |
| `-env:NAME=VALUE` | sets a variable for everything the runner starts, such as `-env:TSNC_GC_STRESS=1`, under which `trees` never finishes; repeatable |
| `-rebuild` | builds the compiler and the runtime even when they are newer than `src/` |
| `-save:NAME` | writes tsnc's median times to `dist/bench/NAME.json` |
| `-against:NAME` | compares tsnc's times with `dist/bench/NAME.json`, which must have been saved with the same flags |
| `-gc` | runs tsnc's programs with `TSNC_GC_STATS=1` and prints their [GC statistics](#gc-statistics) from the median run |

The header lists the flags that change the numbers, so a table from `-o:none` cannot pass for a default one.

To measure a change, save a baseline on `dev` with `bench/bench.sh -save:base trees`, switch to the branch and run `bench/bench.sh -against:base trees`. That table gives the time before, the time now and the change in percent. Node and Go still run once, to check the output, but they are not timed: they are the same before and after. scriptc and Bun do not run at all. On a desktop, the same build of `objects` and `trees` differed by up to 9% from one run of the runner to the next, so a smaller change needs more runs (`-runs:N`) or a repeat before it counts.

The runner prints Markdown, padded so that the columns line up in a terminal too:

- The tables of `bench/RESULTS.md`, when no flag is given. Each program is built with `-o:speed` by tsnc, with `go build`, and by scriptc at its default level, `release`, whatever `-o` says. It runs once under each implementation, and tsnc, Node and Go must exit 0 and print the same output. When scriptc or Bun is missing, cannot build the program, fails or prints something else, its cell is `—` and the reason goes to stderr. One that runs past 30 seconds is killed and its cell is `> 30`: scriptc 0.2.1 never finishes `sieve`. The table gives the median wall time of five more runs, or of 20 for hello, then the size of hello's executable. Bun has no column there: its executable would be Bun itself.
- compile: three generated projects of about a thousand modules under `dist/bench-compile-*` go through `tsnc check` at `-j:1` and at the default `-j`.
  - In `apart` no file uses another's declarations.
  - In `shared` every module calls functions of ten shared lib modules.
  - In `layered` the entry also calls into every module.
  - The last column repeats both runs with tsnc held to one CPU. What stays is the work the checkers repeat, since each types what its files reach in its own table, without what slower cores and shared caches add. Windows only.
  - Last come the `-o:none` and `-o:speed` build times of `layered`.

A timed run writes its output to files: `os.process_exec` polls its pipes without pausing and would keep a core busy. Wall time includes starting the process, the same for all three.

To record a version, run the programs and hello on an idle machine and paste the two tables under a new version heading in `bench/RESULTS.md`, with one line naming the date, the CPU, the OS and the Node and Go versions from the runner's header. CI only type-checks the runner and runs no benchmark: timings on a shared runner say little, and it has no Go.

## Unicode case tables

`toUpperCase` and `toLowerCase` read the tables in `src/runtime/str/case_tables.odin`. A generator writes that file from three files of the Unicode Character Database: `UnicodeData.txt`, `SpecialCasing.txt` and `DerivedCoreProperties.txt`. The version is Unicode 17.0.0, the one Node 24 reports in `process.versions.unicode`, and the first line of the generated file names it.

To regenerate, download the three files into a directory outside the repository and run the generator on it:

```sh
curl -O https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt
curl -O https://www.unicode.org/Public/17.0.0/ucd/SpecialCasing.txt
curl -O https://www.unicode.org/Public/17.0.0/ucd/DerivedCoreProperties.txt
odin run src/runtime/str/tools -out:dist/case-tables.exe -vet -strict-style -- <ucd dir> src/runtime/str/case_tables.odin
```

After a version change, update the hashes in `tests/runtime/str/case_test.odin`: the test maps every code point and compares with Node, and the Node command above it prints the new values. Use a Node whose `process.versions.unicode` is the new version. The generator refuses files that hold a rule the runtime cannot follow, such as a context other than Final_Sigma or a mapping longer than three units. CI only type-checks it.

## Unicode width table

When the console groups a long array into columns, it measures each entry in terminal columns, as Node does: a CJK character takes two, a combining mark none. The widths come from `src/runtime/console/width_tables.odin`, which a generator writes from five files of the same Unicode Character Database 17.0.0. Download them into one directory outside the repository and run the generator on it:

```sh
curl -O https://www.unicode.org/Public/17.0.0/ucd/EastAsianWidth.txt
curl -O https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt
curl -O https://www.unicode.org/Public/17.0.0/ucd/DerivedNormalizationProps.txt
curl -O https://www.unicode.org/Public/17.0.0/ucd/extracted/DerivedGeneralCategory.txt
curl -O https://www.unicode.org/Public/17.0.0/ucd/emoji/emoji-data.txt
odin run src/runtime/console/tools -out:dist/width-tables.exe -vet -strict-style -- <ucd dir> src/runtime/console/width_tables.odin
```

After a version change, update the hash in `tests/runtime/console/width_test.odin`: the test measures every code point and compares with Node's internal `getStringWidth`, which the command above it runs. CI only type-checks the generator.

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs on every push to `main` and `dev` and on every pull request, on four images: `windows-latest`, `ubuntu-latest`, `macos-latest` (arm64) and `macos-26-intel` (x64). Each job builds the compiler and both runtime objects, type-checks the case and width table generators and the benchmark runner, runs `odin test` on every package under `tests/`, then the smoke test, the negative corpus and, after installing Node 24 and TypeScript, the differential and the expected-output corpora twice each: built as usual, each build run as it is and under GC stress, and against the ASan runtime under GC stress. The gc unit tests run once more under ASan. The ASan runtime object and the ASan runs skip both macOS images, for the reason under [AddressSanitizer](#addresssanitizer). The commands are the ones above. A push or a pull request that changes nothing but `docs/`, Markdown files and `.claude/` starts no run.

- Odin: the release `dev-2026-09`, built from commit `a2fb372`, the version the project pins. To move to a newer Odin, change the tag in the workflow. Odin stopped building for Intel Macs after `dev-2026-09`, so a newer Odin on `macos-26-intel` has to be built from source.
- LLVM 20: `llvm-20-dev` from the Ubuntu archive; on macOS the images already carry Homebrew's `llvm@20`. The workflow does not run `brew install`: Homebrew stopped building prebuilt packages for Intel Macs, so on `macos-26-intel` it would build LLVM from source.

## Layout

```
.github/      CI workflow
src/          compiler, package main
src/runtime/  runtime, package rt, built as an object file, and its packages gc (the collector), str,
              arr, value, num, console and fail (runtime errors)
src/abi/      compiler and runtime contract: layouts, tags, type tables, runtime exports
src/llvm/     LLVM-C 20 bindings
src/codegen/  our IR to an LLVM module, then to an object file or textual LLVM IR
src/link/     program and runtime objects to an executable
src/target/   target platforms: LLVM triple, linker, link flags
src/source/   source files: File_ID, spans, lines and columns
src/diag/     compile errors: code registry with hints, sorting, rendering
src/ast/      syntax tree: nodes indexed by Node_ID, import list, traversal
src/parse/    source text to tokens, then to a syntax tree
src/bind/     symbols, scopes, import and export tables, the flow graph
src/program/  the frozen program: every file, its tree, its names, the module graph
src/check/    TypeScript types: the type table, inference, the type rules
src/ir/       our own IR: SSA blocks in flat arrays, interned layouts, the builder
src/lower/    the typed syntax tree to our IR
src/opt/      our IR to our IR: cells on the stack, number ranges, proved indices, integers
src/driver/   the imperative layer: files, arenas, the import closure, the phases
src/lib/      built-in lib.d.ts
tests/        unit tests (one folder per src package, tests/runtime/<package> for the runtime), the
              harness the lower, opt and codegen tests share (source text to IR), the test runner
              and its negative, diff and expect corpora, all.sh
bench/        benchmark programs in bench/ts, their Go twins in bench/go, the runner, RESULTS.md
docs/         requirements, architecture plan, task board, this development guide
dist/         build output, not in git
.claude/      agent notes (CLAUDE.md) and skills, not in git
.zed/         Zed tasks and debug config
```
