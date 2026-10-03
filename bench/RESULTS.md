# Benchmarks

tsnc, scriptc, Node, Bun and Go run the same programs: [ts](ts) and their twins in [go](go). The time is the median of a run in seconds, less is better; hello is the startup time. `—` means the tool is missing, cannot build the program or prints something else; `> 30` means it ran past 30 seconds and was stopped.

To run them, put Node 24 and Go on `PATH` and run [bench.sh](bench.sh), or [bench](bench.cmd) in the Windows shells. scriptc and Bun are optional: `npm install -g scriptc bun`, and on Windows scriptc also needs Zig 0.16. The runner builds the compiler itself; the flags are in [Benchmarks](../docs/development.md#benchmarks).

```sh
bench/bench.sh
```

## After T6.10

2026-10-03, Intel Core i5-13600KF, Windows 11, Node 24.13.1, Go 1.27.0, scriptc 0.2.1, Bun 1.4.2.

| program    | tsnc, s | scriptc, s | Node, s | Bun, s | Go, s |
| ---------- | ------: | ---------: | ------: | -----: | ----: |
| mandelbrot |   0.271 |      0.270 |   0.337 |  0.292 | 0.281 |
| collatz    |   0.739 |      2.149 |   0.972 |  0.840 | 0.178 |
| sieve      |   0.117 |       > 30 |   0.228 |  0.114 | 0.032 |
| chars      |   0.133 |      1.223 |   0.205 |  0.154 | 0.063 |
| strings    |   0.186 |      0.309 |   0.123 |  0.094 | 0.072 |
| objects    |   0.202 |      0.836 |   0.302 |  0.194 | 0.335 |
| closures   |   0.166 |      1.517 |   0.193 |  0.134 | 0.066 |
| trees      |   0.328 |      2.644 |   0.326 |  0.263 | 0.343 |
| raytracer  |   0.603 |          — |   0.460 |  0.479 | 0.210 |
| hello      |   0.004 |      0.004 |   0.048 |  0.012 | 0.005 |

| hello executable | tsnc | scriptc |   Go |
| ---------------- | ---: | ------: | ---: |
| KB               |  312 |     885 | 2433 |

## v1

2026-09-28, Intel Core i5-13600KF, Windows 11, Node 24.13.1, Go 1.27.0.

| program    | tsnc, s | Node, s | Go, s |
| ---------- | ------: | ------: | ----: |
| mandelbrot |   0.272 |   0.338 | 0.282 |
| collatz    |   0.744 |   0.983 | 0.180 |
| sieve      |   0.157 |   0.230 | 0.033 |
| chars      |   0.669 |   0.208 | 0.062 |
| strings    |   0.226 |   0.123 | 0.071 |
| objects    |   0.269 |   0.324 | 0.338 |
| closures   |   0.260 |   0.192 | 0.060 |
| trees      |   1.124 |   0.342 | 0.352 |
| hello      |   0.004 |   0.050 | 0.005 |

| hello executable | tsnc |   Go |
| ---------------- | ---: | ---: |
| KB               |  314 | 2433 |
