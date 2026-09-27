// A module that imports itself is no ring (requirements 7): it always sees itself, so the import
// orders nothing and waits for nothing, though the module runs code as it loads. What it takes is
// its own exports under other names, read after their declarations ran.
import { label as own, twice as again } from "./self-import.ts";

export function twice(n: number): number {
  return n * 2;
}

export const label = "self";

console.log(again(21), own, again === twice);
