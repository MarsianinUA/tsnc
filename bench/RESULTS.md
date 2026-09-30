# Benchmarks

tsnc, Node and Go run the same programs: [ts](ts) and their twins in [go](go). The time is the median of a run in seconds, less is better; hello is the startup time.

To run them, put Node 24 and Go on `PATH` and run [bench.sh](bench.sh), or [bench](bench.cmd) in the Windows shells. It builds the compiler itself; the flags are in [Benchmarks](../docs/development.md#benchmarks).

```sh
bench/bench.sh
```

## v1

2026-09-28, Intel Core i5-13600KF, Windows 11, Node 24.13.1, Go 1.27.0.

| program | tsnc, s | Node, s | Go, s |
| --- | ---: | ---: | ---: |
| mandelbrot | 0.272 | 0.338 | 0.282 |
| collatz | 0.744 | 0.983 | 0.180 |
| sieve | 0.157 | 0.230 | 0.033 |
| chars | 0.669 | 0.208 | 0.062 |
| strings | 0.226 | 0.123 | 0.071 |
| objects | 0.269 | 0.324 | 0.338 |
| closures | 0.260 | 0.192 | 0.060 |
| trees | 1.124 | 0.342 | 0.352 |
| hello | 0.004 | 0.050 | 0.005 |

| hello executable | tsnc | Go |
| --- | ---: | ---: |
| KB | 314 | 2433 |
