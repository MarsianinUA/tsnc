export interface Vec {
  dx: number;
  dy: number;
}

export function lengthOf(v: Vec): number {
  return Math.sqrt(v.dx * v.dx + v.dy * v.dy);
}
