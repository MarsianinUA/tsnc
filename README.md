# tsnc

TypeScript Native Compiler. It compiles a statically typed subset of TypeScript straight to machine code, like Go or Clang. No JavaScript is generated. Written in Odin, with an LLVM 20 backend. It links with LLD on Windows and with the system C compiler on Linux and macOS.

Status: milestone 4 is under way, and the pipeline reaches an executable. `tsnc check` works in full: it reads an entry file, follows its relative imports, parses and binds every file it reaches, builds the module graph, types the whole program, and reports the syntax, subset, type, name and module errors in one pass. `tsnc build` and `tsnc run` carry on from there through our own IR, LLVM and the linker, for the part of the subset that is lowered so far: numbers, strings, booleans, functions, control flow and the `Math`, `console` and `process` calls. Objects, arrays, closures and unions are milestone 5, and a program that uses one is a compile error with a place in it, never a wrong program. A printed number carries the ECMAScript `Number::toString` rules, thresholds and all, so `1e21` and `0.1 + 0.2` read as they do under Node. An artifact is written beside its destination and renamed into place, so a build that fails leaves the program that was there alone. The smoke test (`tests/runner smoke`) builds a hello world through LLVM and the linker, runs it and checks its output. The negative test (`tests/runner negative`) runs `tsnc check` over `tests/negative/`, which holds one program for every rule of the subset and every rule of the types, each failing with the diagnostics its header names. The differential test (`tests/runner diff`) compiles every program in `tests/diff/src/` and checks its output against `node` byte for byte, so the arithmetic, the branches, the printed digits and the exit codes answer to TypeScript itself rather than to a stored expectation. CI runs the build, the unit tests, the smoke test and both corpora on Windows, Linux and macOS (arm64 and x64).

## Docs

- [Requirements](docs/REQUIREMENTS.md): the TypeScript subset, runtime semantics, CLI, quality bar.
- [Architecture plan](docs/architecture-plan-tsnc.md): packages, contracts, milestones.
- [Task board](docs/tasks-tsnc.md): tasks with dependencies and done criteria.

## Commands

Run from the repository root. After cloning, create the output directory once with `mkdir dist`: Odin does not create the `-out:` directory itself, and without it the build fails with `LNK1104`. The directory is not in git.

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
odin build src/runtime -build-mode:obj -use-single-module -out:dist/tsnc_rt-<target>.obj -vet -strict-style

# test runs (smoke from T1.8, negative from T2.9, diff from T4.7); smoke links against the
# runtime object in dist/ and the other two run dist/tsnc.exe, so build both first
odin run tests/runner -out:dist/runner.exe -vet -strict-style -- smoke | negative | diff

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

The compiler CLI follows Odin (see [requirements, section 9](docs/REQUIREMENTS.md#9-platforms-cli-artifacts)):

```sh
tsnc build src/main.ts -out:dist/app.exe            # optimized build
tsnc build src/main.ts -out:dist/app.exe -o:none    # no optimizations, for debugging
tsnc run src/main.ts                                # build and run
tsnc check src/main.ts                              # check only, no code generation
tsnc build src/main.ts -emit-llvm -out:dist/app.ll  # textual LLVM IR
tsnc build src/main.ts -emit-ir -out:dist/app.ir    # custom IR dump for debugging
tsnc build src/main.ts -target:linux_amd64 -j:8     # target and thread count
```

Without `-out:` the artifact is named after the entry file, in the current directory: `tsnc build src/main.ts` writes `main.exe` on Windows and `main` elsewhere, `-emit-llvm` writes `main.ll` and `-emit-ir` writes `main.ir`. `tsnc run` builds the file `tsnc build` would and leaves it there; its exit code is the program's own.

## Differential tests

`tests/diff/src/` holds whole programs, one per construct. `tests/runner diff` runs each under `node`, compiles the same file with `tsnc build` at `-o:none` and at `-o:speed`, runs both and compares stdout, stderr and the exit code byte for byte. Nothing is stored as an expected output: the expectation is what Node prints today.

Two tools are needed, and neither takes any part in a build. **Node 24** runs a `.ts` file directly, which is what makes it a reference; **TypeScript** is the gate, so that a corpus program is TypeScript the real compiler accepts under `--strict` and not merely something tsnc happens to swallow. Both are dev dependencies of `tests/diff/package.json`:

```sh
npm ci --prefix tests/diff
```

`tests/diff/` is laid out as the npm project it is: the manifests at the top, `node_modules/` beside them, the programs under `src/`. They sit above the programs rather than elsewhere in `tests/`, because Node reads `"type": "module"` from the nearest `package.json` and it has to be an ancestor of the programs for an import in one of them to run. `tests/diff/node_modules/` is not in git; `tests/diff/package-lock.json` is, so every machine installs the same compiler. `tests/diff/tsconfig.json` says what the gate compiles and why each of its options is there.

A program in the corpus stays inside the part of the subset that is lowered, since one that does not compile is a failure rather than a skip. `tests/diff/src/modules/` holds modules that other programs import and that are never run on their own.

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs on every push to `main` and `dev` and on every pull request, on four images: `windows-latest`, `ubuntu-latest`, `macos-latest` (arm64) and `macos-26-intel` (x64). Each job builds the compiler and the runtime object, runs `odin test` on every package under `tests/`, then the smoke test, the negative corpus and, after installing Node 24 and TypeScript, the differential corpus, with the commands above.

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
bench/        benchmarks
docs/         requirements, architecture plan, task board
dist/         build output, not in git
.zed/         Zed tasks and debug config
```
