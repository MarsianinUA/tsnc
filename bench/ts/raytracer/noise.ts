// Ken Perlin's improved noise, with the permutation drawn from the generator instead of his table.
import type { Vec } from "./vec.ts";
import { nextInt } from "./rng.ts";

const perm: number[] = [];

export function initNoise(): void {
  const p: number[] = [];
  for (let i = 0; i < 256; i++) {
    p.push(i);
  }
  for (let i = 255; i > 0; i--) {
    const j = nextInt() % (i + 1);
    const t = p[i];
    p[i] = p[j];
    p[j] = t;
  }
  for (let i = 0; i < 512; i++) {
    perm.push(p[i & 255]);
  }
}

function fade(t: number): number {
  return t * t * t * (t * (t * 6 - 15) + 10);
}

function mix(t: number, a: number, b: number): number {
  return a + t * (b - a);
}

function grad(hash: number, x: number, y: number, z: number): number {
  switch (hash & 15) {
    case 0:
      return x + y;
    case 1:
      return -x + y;
    case 2:
      return x - y;
    case 3:
      return -x - y;
    case 4:
      return x + z;
    case 5:
      return -x + z;
    case 6:
      return x - z;
    case 7:
      return -x - z;
    case 8:
      return y + z;
    case 9:
      return -y + z;
    case 10:
      return y - z;
    case 11:
      return -y - z;
    case 12:
      return y + x;
    case 13:
      return -y + z;
    case 14:
      return y - x;
    default:
      return -y - z;
  }
}

export function noise(x: number, y: number, z: number): number {
  const fx = Math.floor(x);
  const fy = Math.floor(y);
  const fz = Math.floor(z);
  const cx = fx & 255;
  const cy = fy & 255;
  const cz = fz & 255;
  const dx = x - fx;
  const dy = y - fy;
  const dz = z - fz;
  const u = fade(dx);
  const v = fade(dy);
  const w = fade(dz);
  const a = perm[cx] + cy;
  const aa = perm[a] + cz;
  const ab = perm[a + 1] + cz;
  const b = perm[cx + 1] + cy;
  const ba = perm[b] + cz;
  const bb = perm[b + 1] + cz;
  const near = mix(
    v,
    mix(u, grad(perm[aa], dx, dy, dz), grad(perm[ba], dx - 1, dy, dz)),
    mix(u, grad(perm[ab], dx, dy - 1, dz), grad(perm[bb], dx - 1, dy - 1, dz)),
  );
  const far = mix(
    v,
    mix(u, grad(perm[aa + 1], dx, dy, dz - 1), grad(perm[ba + 1], dx - 1, dy, dz - 1)),
    mix(u, grad(perm[ab + 1], dx, dy - 1, dz - 1), grad(perm[bb + 1], dx - 1, dy - 1, dz - 1)),
  );
  return mix(w, near, far);
}

// Fractional Brownian motion.
export function fbm(p: Vec, octaves: number): number {
  let sum = 0;
  let amplitude = 1;
  let frequency = 1;
  for (let i = 0; i < octaves; i++) {
    sum += amplitude * noise(p.x * frequency, p.y * frequency, p.z * frequency);
    amplitude *= 0.5;
    frequency *= 2;
  }
  return sum;
}
