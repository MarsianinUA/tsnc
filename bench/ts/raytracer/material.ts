import type { Vec } from "./vec.ts";
import { lerp, scale } from "./vec.ts";
import { fbm, noise } from "./noise.ts";

export type Texture = (p: Vec) => Vec;

export type Kind = "diffuse" | "mirror" | "glass";

export interface Material {
  readonly name: string;
  readonly kind: Kind;
  readonly texture: Texture;
  readonly specular: number;
  readonly shininess: number;
  readonly reflectivity: number;
  readonly ior: number;
  readonly emission?: Vec;
}

export function solid(color: Vec): Texture {
  return () => color;
}

export function checker(a: Vec, b: Vec, size: number): Texture {
  return (p) => {
    const cell = Math.floor(p.x / size) + Math.floor(p.y / size) + Math.floor(p.z / size);
    return (cell & 1) === 0 ? a : b;
  };
}

// A triangle wave in [0, 1], where marble usually takes a sine.
function wave(x: number): number {
  return Math.abs(x - 2 * Math.floor(x * 0.5) - 1);
}

export function marble(a: Vec, b: Vec, frequency: number): Texture {
  return (p) => lerp(a, b, wave(p.x * frequency + 4 * fbm(scale(p, frequency), 4)));
}

export function wood(a: Vec, b: Vec, frequency: number): Texture {
  return (p) => {
    const ring = Math.sqrt(p.x * p.x + p.z * p.z) * frequency + 2 * noise(p.x, p.y * 4, p.z);
    return lerp(a, b, ring - Math.floor(ring));
  };
}

export function strata(low: Vec, high: Vec, from: number, to: number): Texture {
  return (p) => {
    const h = p.y + 0.4 * noise(p.x * 3, 0.5, p.z * 3);
    if (h <= from) {
      return low;
    }
    if (h >= to) {
      return high;
    }
    return lerp(low, high, (h - from) / (to - from));
  };
}
