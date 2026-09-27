// A module whose top level runs code. It runs once, before anything that imports it, and this line
// is how the order is observed from the outside.
console.log("counter loads");

export const start = 10;

export function step(n: number): number {
  return n + start;
}

// The importers read this binding, not a copy of it, so they see every write bump makes.
export let count = 0;

export function bump(): void {
  count += 1;
}
