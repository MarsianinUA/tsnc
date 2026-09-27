export type Shape = { kind: "circle"; r: number } | { kind: "square"; side: number };

export function area(shape: Shape): number {
  if (shape.kind === "circle") {
    return 3 * shape.r * shape.r;
  }
  return shape.side * shape.side;
}
