import type { Vec } from "./geometry.ts";

export interface Offset {
  dx: number;
  dy: number;
}

export function toVec(o: Offset): Vec {
  return o;
}

export function each(vs: Vec[], f: (v: Vec, i: number) => number): number[] {
  const out: number[] = [];
  for (let i = 0; i < vs.length; i++) {
    out.push(f(vs[i], i));
  }
  return out;
}
