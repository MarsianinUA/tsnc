// Every operation returns a new object, the way TypeScript code usually reads: what those
// allocations cost is part of what the benchmark measures.
export interface Vec {
  readonly x: number;
  readonly y: number;
  readonly z: number;
}

export interface Ray {
  readonly origin: Vec;
  readonly dir: Vec;
}

export function vec(x: number, y: number, z: number): Vec {
  return { x, y, z };
}

export function add(a: Vec, b: Vec): Vec {
  return { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z };
}

export function sub(a: Vec, b: Vec): Vec {
  return { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z };
}

export function mul(a: Vec, b: Vec): Vec {
  return { x: a.x * b.x, y: a.y * b.y, z: a.z * b.z };
}

export function scale(a: Vec, s: number): Vec {
  return { x: a.x * s, y: a.y * s, z: a.z * s };
}

export function addScaled(a: Vec, b: Vec, s: number): Vec {
  return { x: a.x + b.x * s, y: a.y + b.y * s, z: a.z + b.z * s };
}

export function negate(a: Vec): Vec {
  return { x: -a.x, y: -a.y, z: -a.z };
}

export function dot(a: Vec, b: Vec): number {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

export function cross(a: Vec, b: Vec): Vec {
  return {
    x: a.y * b.z - a.z * b.y,
    y: a.z * b.x - a.x * b.z,
    z: a.x * b.y - a.y * b.x,
  };
}

export function length(a: Vec): number {
  return Math.sqrt(dot(a, a));
}

export function normalize(a: Vec): Vec {
  const len = length(a);
  return { x: a.x / len, y: a.y / len, z: a.z / len };
}

export function lerp(a: Vec, b: Vec, t: number): Vec {
  return addScaled(a, sub(b, a), t);
}

export function minVec(a: Vec, b: Vec): Vec {
  return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), z: Math.min(a.z, b.z) };
}

export function maxVec(a: Vec, b: Vec): Vec {
  return { x: Math.max(a.x, b.x), y: Math.max(a.y, b.y), z: Math.max(a.z, b.z) };
}

export function component(a: Vec, axis: number): number {
  return axis === 0 ? a.x : axis === 1 ? a.y : a.z;
}

export function at(ray: Ray, t: number): Vec {
  return addScaled(ray.origin, ray.dir, t);
}

export function reflect(d: Vec, n: Vec): Vec {
  return addScaled(d, n, -2 * dot(d, n));
}

// Snell's law for a unit d and a unit n facing it; null on total internal reflection.
export function refract(d: Vec, n: Vec, eta: number): Vec | null {
  const cosi = -dot(d, n);
  const k = 1 - eta * eta * (1 - cosi * cosi);
  if (k < 0) {
    return null;
  }
  return addScaled(scale(d, eta), n, eta * cosi - Math.sqrt(k));
}
