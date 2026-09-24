// A module the program imports as a namespace. Its top level runs once, before the program's own,
// however many import declarations name it.
console.log("geometry loads");

export interface Point {
  x: number;
  y: number;
}

export const SIDES = 4;

export const origin: Point = { x: 0, y: 0 };

export function distance(a: Point, b: Point): number {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  return Math.sqrt(dx * dx + dy * dy);
}

export function scale(p: Point, by: number): Point {
  return { x: p.x * by, y: p.y * by };
}
