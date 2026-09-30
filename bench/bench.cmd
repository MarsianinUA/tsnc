@echo off
rem The benchmark runner, from any directory: bench\bench [names] [flags]. Odin does not create the
rem -out: directory itself.
setlocal
pushd "%~dp0.."
if not exist dist mkdir dist
odin run bench/runner -out:dist/bench.exe -vet -strict-style -- %*
set code=%errorlevel%
popd
exit /b %code%
