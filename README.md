# tsnc

TypeScript Native Compiler. It compiles a statically typed subset of TypeScript straight to machine code, like Go or Clang. No JavaScript is generated. Written in Odin, with an LLVM 20 backend and LLD for linking.

Status: milestone 1. The CLI parses its flags and answers "not implemented" with exit code 1.

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
odin test tests/<package> -out:dist/<package>-tests.exe -vet -strict-style

# runtime object (from T1.5)
odin build src/runtime -build-mode:obj -out:dist/tsnc_rt-<target>.obj -vet -strict-style

# test runs (smoke from T1.8, negative from T2.9, diff from T4.7)
odin run tests/runner -out:dist/runner.exe -- smoke | negative | diff
```

`-vet -strict-style` is part of every build, so there is no separate linter. An unused variable, a stray semicolon or spaces instead of tabs fail the build.

## LLVM

The compiler calls LLVM 20 through its C API (package `src/llvm`).

- Windows: `LLVM-C.dll` ships with Odin next to `odin.exe`. That directory must be on `PATH` when you run `tsnc.exe` or the `llvm` package tests. The import library is in the repository: `src/llvm/windows/LLVM-C.lib`.
- Linux and macOS: install LLVM 20 (`llvm-20-dev` from apt.llvm.org, `llvm@20` from Homebrew). How the build finds it gets set up together with CI.

The compiler CLI follows Odin (see [requirements, section 9](docs/REQUIREMENTS.md#9-platforms-cli-artifacts)):

```sh
tsnc build src/main.ts -out:dist/app.exe            # optimized build
tsnc build src/main.ts -out:dist/app.exe -o:none    # no optimizations, for debugging
tsnc run src/main.ts                                # build and run
tsnc check src/main.ts                              # check only, no code generation
tsnc build src/main.ts -emit-llvm -out:dist/app.ll  # textual LLVM IR
tsnc build src/main.ts -emit-ir -out:dist/app.ir    # tsnc IR dump
tsnc build src/main.ts -target:linux_amd64 -j:8     # target and thread count
```

## Layout

```
src/          compiler, package main
src/runtime/  runtime, package rt, built as an object file
src/abi/      compiler and runtime contract: layouts, tags, type tables, runtime exports
src/llvm/     LLVM-C 20 bindings
src/lib/      built-in lib.d.ts
tests/        unit tests (one folder per src package), test runner, test corpora
bench/        benchmarks
docs/         requirements, architecture plan, task board
dist/         build output, not in git
.zed/         Zed tasks and debug config
```
