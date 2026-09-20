// A module that imports another one. Its own top level runs after the one it depends on.
import { start } from "./counter.ts";

console.log("greeting loads");

export const banner = "ready";

export function offset(): number {
  return start * 2;
}
