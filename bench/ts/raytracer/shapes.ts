import type { Material } from "./material.ts";
import type { Ray, Vec } from "./vec.ts";
import {
  add,
  addScaled,
  at,
  cross,
  dot,
  maxVec,
  minVec,
  normalize,
  scale,
  sub,
  vec,
} from "./vec.ts";
import { stats } from "./stats.ts";

export interface Sphere {
  readonly kind: "sphere";
  readonly center: Vec;
  readonly radius: number;
  readonly material: Material;
}

// The points p with dot(normal, p) === offset.
export interface Plane {
  readonly kind: "plane";
  readonly normal: Vec;
  readonly offset: number;
  readonly material: Material;
}

// e1 and e2 are the edges from a; na, nb and nc are the normals at a, b and c.
export interface Triangle {
  readonly kind: "triangle";
  readonly a: Vec;
  readonly e1: Vec;
  readonly e2: Vec;
  readonly na: Vec;
  readonly nb: Vec;
  readonly nc: Vec;
  readonly material: Material;
}

// A plane has no bounds, so it stays out of the BVH.
export type Solid = Sphere | Triangle;
export type Shape = Sphere | Plane | Triangle;

export interface Hit {
  readonly t: number;
  readonly point: Vec;
  readonly normal: Vec;
  readonly material: Material;
}

export interface Box {
  readonly min: Vec;
  readonly max: Vec;
}

// A hit nearer than this is the surface the ray starts on.
export const T_MIN = 1e-4;

export function sphere(center: Vec, radius: number, material: Material): Sphere {
  return { kind: "sphere", center, radius, material };
}

export function triangle(
  a: Vec,
  b: Vec,
  c: Vec,
  na: Vec,
  nb: Vec,
  nc: Vec,
  material: Material,
): Triangle {
  return { kind: "triangle", a, e1: sub(b, a), e2: sub(c, a), na, nb, nc, material };
}

export function intersect(shape: Shape, ray: Ray, tMax: number): Hit | null {
  stats.shapeTests++;
  switch (shape.kind) {
    case "sphere":
      return hitSphere(shape, ray, tMax);
    case "plane":
      return hitPlane(shape, ray, tMax);
    case "triangle":
      return hitTriangle(shape, ray, tMax);
  }
}

function hitSphere(s: Sphere, ray: Ray, tMax: number): Hit | null {
  const oc = sub(ray.origin, s.center);
  const b = dot(oc, ray.dir);
  const c = dot(oc, oc) - s.radius * s.radius;
  const disc = b * b - c;
  if (disc < 0) {
    return null;
  }
  const root = Math.sqrt(disc);
  let t = -b - root;
  if (t <= T_MIN || t >= tMax) {
    t = -b + root;
    if (t <= T_MIN || t >= tMax) {
      return null;
    }
  }
  const point = at(ray, t);
  return { t, point, normal: scale(sub(point, s.center), 1 / s.radius), material: s.material };
}

function hitPlane(plane: Plane, ray: Ray, tMax: number): Hit | null {
  const denom = dot(plane.normal, ray.dir);
  if (Math.abs(denom) < 1e-9) {
    return null;
  }
  const t = (plane.offset - dot(plane.normal, ray.origin)) / denom;
  if (t <= T_MIN || t >= tMax) {
    return null;
  }
  return { t, point: at(ray, t), normal: plane.normal, material: plane.material };
}

// Moller-Trumbore.
function hitTriangle(tri: Triangle, ray: Ray, tMax: number): Hit | null {
  const p = cross(ray.dir, tri.e2);
  const det = dot(tri.e1, p);
  if (det > -1e-12 && det < 1e-12) {
    return null;
  }
  const inv = 1 / det;
  const s = sub(ray.origin, tri.a);
  const u = dot(s, p) * inv;
  if (u < 0 || u > 1) {
    return null;
  }
  const q = cross(s, tri.e1);
  const v = dot(ray.dir, q) * inv;
  if (v < 0 || u + v > 1) {
    return null;
  }
  const t = dot(tri.e2, q) * inv;
  if (t <= T_MIN || t >= tMax) {
    return null;
  }
  const w = 1 - u - v;
  const normal = normalize(addScaled(addScaled(scale(tri.na, w), tri.nb, u), tri.nc, v));
  return { t, point: at(ray, t), normal, material: tri.material };
}

export function bounds(shape: Solid): Box {
  switch (shape.kind) {
    case "sphere": {
      const r = vec(shape.radius, shape.radius, shape.radius);
      return { min: sub(shape.center, r), max: add(shape.center, r) };
    }
    case "triangle": {
      const b = add(shape.a, shape.e1);
      const c = add(shape.a, shape.e2);
      return { min: minVec(minVec(shape.a, b), c), max: maxVec(maxVec(shape.a, b), c) };
    }
  }
}

export function centroid(shape: Solid): Vec {
  switch (shape.kind) {
    case "sphere":
      return shape.center;
    case "triangle":
      return addScaled(shape.a, add(shape.e1, shape.e2), 1 / 3);
  }
}
