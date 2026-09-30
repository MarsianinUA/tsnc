#!/bin/sh
# The benchmark runner, from any directory: bench/bench.sh [names] [flags]. Odin does not create the
# -out: directory itself.
cd "$(dirname "$0")/.." || exit 1
mkdir -p dist
exec odin run bench/runner -out:dist/bench.exe -vet -strict-style -- "$@"
