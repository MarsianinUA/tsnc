export function makeCounter(start: number): () => number {
  let n = start;
  return () => {
    n += 1;
    return n;
  };
}
