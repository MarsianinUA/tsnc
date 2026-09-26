# Development

How to build tsnc from source, run its tests and find your way around the repository.

## Commands

Run from the repository root. After cloning, create the output directory once with `mkdir dist`. Odin does not create the `-out:` directory itself, and without it the build fails with `LNK1104`. The directory is not in git.

```sh
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

# test runs (smoke from T1.8, negative from T2.9, diff from T4.7); smoke links against the
# runtime object in dist/ and the other two run dist/tsnc.exe, so build both first
odin run tests/runner -out:dist/runner.exe -vet -strict-style -- smoke
odin run tests/runner -out:dist/runner.exe -vet -strict-style -- negative
odin run tests/runner -out:dist/runner.exe -vet -strict-style -- diff

# the diff corpus needs Node 24 and TypeScript, installed once from tests/diff/package.json
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

## Differential tests

`tests/diff/src/` holds whole programs, one per construct. `tests/runner diff` runs each under `node`, compiles the same file with `tsnc build` at `-o:none` and at `-o:speed`, runs both and compares stdout, stderr and the exit code byte for byte. Nothing is stored as an expected output: the expectation is what Node prints today.

Two tools are needed, and neither takes any part in a build. Node 24 runs a `.ts` file directly, which is what makes it a reference. TypeScript is the gate, so that a corpus program is TypeScript the real compiler accepts under `--strict` and not merely something tsnc happens to swallow. Both are dev dependencies of `tests/diff/package.json`:

```sh
npm ci --prefix tests/diff
```

`tests/diff/` is laid out as the npm project it is: the manifests at the top, `node_modules/` beside them, the programs under `src/`. They sit above the programs rather than elsewhere in `tests/`, because Node reads `"type": "module"` from the nearest `package.json` and it has to be an ancestor of the programs for an import in one of them to run. `tests/diff/node_modules/` is not in git; `tests/diff/package-lock.json` is, so every machine installs the same compiler. `tests/diff/tsconfig.json` says what the gate compiles and why each of its options is there.

A program in the corpus stays inside the part of the subset that is lowered, since one that does not compile is a failure rather than a skip. `tests/diff/src/modules/` holds modules that other programs import and that are never run on their own.

A program may start with two header lines, each at most once and in either order, and the runner applies both to the Node run and to the compiled one. `// env:` sets environment variables on top of the runner's own environment:

```ts
// env: FORCE_COLOR=1 NO_COLOR= NODE_DISABLE_COLORS=
```

`tests/diff/src/colors.ts` does this to see colors through the pipe the runner reads. The two empty values keep Node from warning that they are ignored, should the machine set them.

`// args:` passes command line arguments after the program. They are split on whitespace, with no quoting:

```ts
// args: one two --flag=x
```

`tests/diff/src/process-argv.ts` reads them from `process.argv`, a Cyrillic word and a character outside the BMP among them. It prints nothing from the first two entries, the executable and the script, since those differ between Node and the build.

## GC stress mode

A compiled program runs its collector in stress mode when the environment variable `TSNC_GC_STRESS` is `1`, with no rebuild. It then collects before every allocation and checks the whole heap after every collection. A broken heap ends the program with exit code 1 and the address of the cell, page or free list where the check stopped:

```
error: internal error: heap check failed: dangling reference: 0x1f2c0010040
```

The runtime reads the variable once, at startup. Every check walks the whole heap, so a program that allocates a lot runs far slower in this mode.

To run the differential corpus in this mode, set the variable for the runner; the programs it builds inherit it, and Node and tsc ignore it. CI runs the corpus both ways.

```sh
TSNC_GC_STRESS=1 odin run tests/runner -out:dist/runner.exe -vet -strict-style -- diff
```

Three programs of the corpus exist for the collector: `gc-objects.ts`, `gc-closures.ts` and `gc-large.ts` allocate enough to collect at least three times in the normal mode, where the first collection waits for 4 MiB. Each builds its bytes out of few allocations, long strings by doubling and whole arrays, so that under stress, where every allocation collects and checks the heap, a build still runs in about two seconds.

## AddressSanitizer

`tsnc build -sanitize:address` and `tsnc run -sanitize:address` link the runtime built with AddressSanitizer, `tsnc_rt-<target>-asan.obj` next to `tsnc.exe`, which the second runtime command under [Commands](#commands) builds. Only the runtime is instrumented; the code tsnc generates is not.

In that build the collector tells ASan which bytes of its heap a program may touch: the cells in use and the first 16 bytes of each free slot, which hold its free list link. It poisons the rest, as Go's sweep does, so a runtime procedure that reads past the end of a cell or into the body of a freed one stops with ASan's report. A freed cell's first 16 bytes stay open, so a use after free that touches only a length or a header goes unnoticed.

ASan's fake stack is off. With it, every local whose address is taken moves to memory of ASan's own, the stack base the runtime hands the collector among them, and the stack scan would read past the real stack. The runtime answers `detect_stack_use_after_return=0` from `__asan_default_options`; `ASAN_OPTIONS` still overrides it. The gc unit tests have no runtime around them, so they need the variable:

```sh
ASAN_OPTIONS=detect_stack_use_after_return=0 odin test tests/runtime/gc -out:dist/runtime-gc-asan-tests.exe -vet -strict-style -sanitize:address -define:TSNC_EXPECT_ASAN=true
TSNC_GC_STRESS=1 odin run tests/runner -out:dist/runner.exe -vet -strict-style -- diff -sanitize:address
```

The define makes the first command fail if the build lost the sanitizer, where every ASan test would pass with nothing checked. The second command runs the differential corpus against the ASan runtime in stress mode, where every allocation collects, so each cell is poisoned the moment it dies. CI runs both.

`-sanitize:address` works on Windows and Linux. On macOS tsnc refuses it before linking anything, since the link would fail: `cc` is Xcode's clang, whose ASan runtime names its version check after Apple's clang, while the runtime object is instrumented by LLVM 20 and asks for `___asan_version_mismatch_check_v8`. Linking through the clang of Homebrew's `llvm@20` instead was tried in CI: the program died with SIGILL on the Intel image and hung on arm64 macOS 26, as [llvm-project issue 200447](https://github.com/llvm/llvm-project/issues/200447) reports for a one-line C program. So CI builds and runs ASan on Windows and Linux only, the way CPython runs ASan on Linux only and `go build -asan` exists only on Linux. The poisoning is the same code on every OS.


## Benchmarks

`bench/runner` builds `bench/hello.ts` with `dist/tsnc.exe -o:speed` and prints the size of the executable and the startup time, the fastest and the median of 20 runs, next to `node bench/hello.ts`. It needs the compiler and the runtime object, and Node on `PATH`.

```sh
odin run bench/runner -out:dist/bench.exe -vet -strict-style
```

CI only type-checks it: timings on a shared runner say little. The benchmarks against Node and Go come with milestone 6.

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

GitHub Actions (`.github/workflows/ci.yml`) runs on every push to `main` and `dev` and on every pull request, on four images: `windows-latest`, `ubuntu-latest`, `macos-latest` (arm64) and `macos-26-intel` (x64). Each job builds the compiler and both runtime objects, type-checks the case and width table generators and the benchmark runner, runs `odin test` on every package under `tests/`, then the smoke test, the negative corpus and, after installing Node 24 and TypeScript, the differential corpus three times: as it is, under GC stress, and against the ASan runtime under GC stress. The gc unit tests run once more under ASan. The ASan runtime object and the two ASan runs skip both macOS images, for the reason under [AddressSanitizer](#addresssanitizer). The commands are the ones above.

- Odin: the release `dev-2026-09`, built from commit `a2fb372`, the version the project pins. To move to a newer Odin, change the tag in the workflow. Odin stopped building for Intel Macs after `dev-2026-09`, so a newer Odin on `macos-26-intel` has to be built from source.
- LLVM 20: `llvm-20-dev` from the Ubuntu archive; on macOS the images already carry Homebrew's `llvm@20`. The workflow does not run `brew install`: Homebrew stopped building prebuilt packages for Intel Macs, so on `macos-26-intel` it would build LLVM from source.

## Layout

```
.github/      CI workflow
src/          compiler, package main
src/runtime/  runtime, package rt, built as an object file
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
src/driver/   the imperative layer: files, arenas, the import closure, the phases
src/lib/      built-in lib.d.ts
tests/        unit tests (one folder per src package), test runner, negative and diff corpora
bench/        benchmarks: the hello world starter and its runner
docs/         requirements, architecture plan, task board, this development guide
dist/         build output, not in git
.zed/         Zed tasks and debug config
```
