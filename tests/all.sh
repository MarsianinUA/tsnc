#!/bin/bash
# What CI runs, on this machine, from any directory: tests/all.sh. One line per step; the output of
# every step goes to dist/all.log. A failed step does not stop the others, so one run shows every
# failure. The ASan steps skip macOS for the reason in docs/development.md, "AddressSanitizer".
cd "$(dirname "$0")/.." || exit 1
mkdir -p dist
# On Windows LLVM-C.dll sits next to odin.exe, and the llvm and codegen tests load it.
PATH="$(dirname "$(command -v odin)"):$PATH"

case "$(uname -s)-$(uname -m)" in
MINGW* | MSYS* | CYGWIN*) target=windows_amd64 ;;
Linux-x86_64) target=linux_amd64 ;;
Darwin-arm64) target=darwin_arm64 ;;
Darwin-x86_64) target=darwin_amd64 ;;
*)
	echo "tests/all.sh: no tsnc target for $(uname -s) $(uname -m)" >&2
	exit 1
	;;
esac
asan=yes
[ "$(uname -s)" = Darwin ] && asan=no

log=dist/all.log
: > "$log"
failed=()

step() {
	local name=$1 start=$SECONDS
	shift
	echo "=== $name" >> "$log"
	if "$@" >> "$log" 2>&1; then
		printf 'ok      %-28s %4d s\n' "$name" $((SECONDS - start))
	else
		printf 'FAILED  %-28s %4d s\n' "$name" $((SECONDS - start))
		failed+=("$name")
	fi
}

step "compiler" odin build src -out:dist/tsnc.exe -o:speed -vet -strict-style
step "runtime" odin build src/runtime -build-mode:obj -use-single-module -o:speed \
	-out:dist/tsnc_rt-$target.obj -vet -strict-style
[ $asan = yes ] && step "runtime with ASan" odin build src/runtime -build-mode:obj -use-single-module \
	-o:speed -sanitize:address -out:dist/tsnc_rt-$target-asan.obj -vet -strict-style
step "table generators" sh -c 'odin check src/runtime/str/tools -vet -strict-style &&
	odin check src/runtime/console/tools -vet -strict-style'
step "benchmark runner" odin check bench/runner -vet -strict-style

shopt -s nullglob
for dir in tests/*/ tests/*/*/; do
	dir=${dir%/}
	files=("$dir"/*_test.odin)
	[ ${#files[@]} -gt 0 ] || continue
	name=${dir#tests/}
	step "$name" odin test "$dir" -out:"dist/${name//\//-}-tests.exe" -vet -strict-style
done

[ -d tests/diff/node_modules ] || step "npm ci" npm ci --prefix tests/diff
step "runner" odin build tests/runner -out:dist/runner.exe -vet -strict-style
for mode in smoke negative diff expect; do
	step "$mode" dist/runner.exe $mode
done
for mode in diff expect; do
	step "$mode under GC stress" env TSNC_GC_STRESS=1 dist/runner.exe $mode
done
if [ $asan = yes ]; then
	step "gc under ASan" env ASAN_OPTIONS=detect_stack_use_after_return=0 odin test tests/runtime/gc \
		-out:dist/runtime-gc-asan-tests.exe -vet -strict-style -sanitize:address -define:TSNC_EXPECT_ASAN=true
	for mode in diff expect; do
		step "$mode under ASan" env TSNC_GC_STRESS=1 dist/runner.exe $mode -sanitize:address
	done
fi

if [ ${#failed[@]} -gt 0 ]; then
	echo "failed: ${failed[*]}; the output is in dist/all.log"
	exit 1
fi
echo "all green"
