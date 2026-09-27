import type { Vec } from "./geometry.ts";

export function describe(v: number | string | Vec): string {
  if (typeof v === "number") {
    return "number " + v;
  }
  if (typeof v === "string") {
    return "string " + v;
  }
  return "vec " + v.dx + "," + v.dy;
}
