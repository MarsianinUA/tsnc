// The largest module of the project, and the first one main imports: with several threads the
// small modules after it finish parsing before it does, which the numbering must not follow.
import { depth } from "./deep.ts";

export interface Square {
  kind: "square";
  size: number;
}

export interface Rectangle {
  kind: "rectangle";
  width: number;
  height: number;
}

export interface Circle {
  kind: "circle";
  radius: number;
}

export type Shape = Square | Rectangle | Circle;

export function area(shape: Shape): number {
  if (shape.kind === "square") {
    return shape.size * shape.size;
  }
  if (shape.kind === "rectangle") {
    return shape.width * shape.height;
  }
  return Math.PI * shape.radius * shape.radius;
}

export function perimeter(shape: Shape): number {
  if (shape.kind === "square") {
    return 4 * shape.size;
  }
  if (shape.kind === "rectangle") {
    return 2 * (shape.width + shape.height);
  }
  return 2 * Math.PI * shape.radius;
}

export function total(shapes: Shape[]): number {
  let sum = 0;
  for (const shape of shapes) {
    sum = sum + area(shape);
  }
  return sum;
}

export function largest(shapes: Shape[]): number {
  let best = 0;
  for (let i = 0; i < shapes.length; i++) {
    const next = area(shapes[i]);
    if (next > best) {
      best = next;
    }
  }
  return best;
}

export function describe(shape: Shape): string {
  return `${shape.kind}: area ${area(shape)}, perimeter ${perimeter(shape)}, depth ${depth}`;
}

export function scaled(shape: Shape, factor: number): Shape {
  if (shape.kind === "square") {
    return { kind: "square", size: shape.size * factor };
  }
  if (shape.kind === "rectangle") {
    return { kind: "rectangle", width: shape.width * factor, height: shape.height * factor };
  }
  return { kind: "circle", radius: shape.radius * factor };
}

const unit = 1;
const unit = 2;
