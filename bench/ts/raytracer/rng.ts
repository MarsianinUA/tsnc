// Park-Miller, as in the other benchmarks.
let seed = 1;

export function reseed(value: number): void {
  seed = value;
}

export function nextInt(): number {
  seed = (seed * 16807) % 2147483647;
  return seed;
}

// In [0, 1).
export function nextFloat(): number {
  return (nextInt() - 1) / 2147483646;
}
