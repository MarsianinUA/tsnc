// Takes only a type from type-ring-b, which imports a value back from here: a ring of two modules
// that both run code as they load, were the type-only import an edge.
import type { Later } from "./type-ring-b.ts";

console.log("type-ring-a loads");

export const first = 1;

export function describe(later: Later): string {
  return later.name;
}
