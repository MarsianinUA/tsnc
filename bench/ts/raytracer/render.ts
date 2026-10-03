import type { Node } from "./bvh.ts";
import { closest, occluded } from "./bvh.ts";
import type { Material } from "./material.ts";
import type { Scene } from "./parse.ts";
import type { Hit } from "./shapes.ts";
import { intersect } from "./shapes.ts";
import type { Ray, Vec } from "./vec.ts";
import {
  add,
  addScaled,
  cross,
  dot,
  length,
  lerp,
  mul,
  negate,
  normalize,
  reflect,
  refract,
  scale,
  sub,
  vec,
} from "./vec.ts";
import { nextFloat } from "./rng.ts";
import { stats } from "./stats.ts";

const MAX_DEPTH = 5;

// How far a secondary ray starts off the surface, so that it does not hit the surface again.
const BIAS = 1e-3;

const BLACK = vec(0, 0, 0);

function closestHit(scene: Scene, root: Node, ray: Ray): Hit | null {
  let best = closest(root, ray, Infinity);
  for (const plane of scene.planes) {
    const hit = intersect(plane, ray, best === null ? Infinity : best.t);
    if (hit !== null) {
      best = hit;
    }
  }
  return best;
}

function inShadow(scene: Scene, root: Node, ray: Ray, distance: number): boolean {
  stats.shadowRays++;
  if (occluded(root, ray, distance)) {
    return true;
  }
  for (const plane of scene.planes) {
    if (intersect(plane, ray, distance) !== null) {
      return true;
    }
  }
  return false;
}

// n must be a whole number.
function power(x: number, n: number): number {
  let result = 1;
  let base = x;
  let e = n;
  while (e > 0) {
    if ((e & 1) === 1) {
      result *= base;
    }
    base *= base;
    e >>= 1;
  }
  return result;
}

// Lambert and Phong over the lights that see the point: base is the surface color, black for a
// surface that only reflects, which then keeps the highlights alone.
function direct(scene: Scene, root: Node, hit: Hit, normal: Vec, view: Vec, base: Vec): Vec {
  const material = hit.material;
  const origin = addScaled(hit.point, normal, BIAS);
  let color = mul(base, scene.ambient);
  for (const light of scene.lights) {
    const toLight = sub(light.position, origin);
    const distance = length(toLight);
    const l = scale(toLight, 1 / distance);
    const lambert = dot(normal, l);
    if (lambert <= 0 || inShadow(scene, root, { origin, dir: l }, distance)) {
      continue;
    }
    color = addScaled(color, mul(base, light.color), lambert);
    if (material.specular > 0) {
      const highlight = -dot(reflect(negate(l), normal), view);
      if (highlight > 0) {
        color = addScaled(
          color,
          light.color,
          material.specular * power(highlight, material.shininess),
        );
      }
    }
  }
  return color;
}

function bounce(scene: Scene, root: Node, origin: Vec, dir: Vec, depth: number): Vec {
  return trace(scene, root, { origin, dir }, depth + 1);
}

function shade(
  scene: Scene,
  root: Node,
  ray: Ray,
  hit: Hit,
  normal: Vec,
  inside: boolean,
  depth: number,
): Vec {
  const material: Material = hit.material;
  const outside = addScaled(hit.point, normal, BIAS);
  switch (material.kind) {
    case "diffuse": {
      const lit = direct(scene, root, hit, normal, ray.dir, material.texture(hit.point));
      if (material.reflectivity <= 0 || depth >= MAX_DEPTH) {
        return lit;
      }
      const mirrored = bounce(scene, root, outside, reflect(ray.dir, normal), depth);
      return lerp(lit, mirrored, material.reflectivity);
    }
    case "mirror": {
      const lit = direct(scene, root, hit, normal, ray.dir, BLACK);
      if (depth >= MAX_DEPTH) {
        return lit;
      }
      const mirrored = bounce(scene, root, outside, reflect(ray.dir, normal), depth);
      return add(lit, mul(material.texture(hit.point), mirrored));
    }
    case "glass": {
      const lit = direct(scene, root, hit, normal, ray.dir, BLACK);
      if (depth >= MAX_DEPTH) {
        return lit;
      }
      const tint = material.texture(hit.point);
      const mirrored = bounce(scene, root, outside, reflect(ray.dir, normal), depth);
      const eta = inside ? material.ior : 1 / material.ior;
      const bent = refract(ray.dir, normal, eta);
      if (bent === null) {
        return add(lit, mul(tint, mirrored));
      }
      const through = bounce(scene, root, addScaled(hit.point, normal, -BIAS), bent, depth);
      // Schlick's approximation of the share of light the surface reflects.
      const r = (1 - material.ior) / (1 + material.ior);
      const f0 = r * r;
      const m = 1 + dot(ray.dir, normal);
      const fresnel = f0 + (1 - f0) * power(m, 5);
      return add(lit, mul(tint, lerp(through, mirrored, fresnel)));
    }
  }
}

function trace(scene: Scene, root: Node, ray: Ray, depth: number): Vec {
  stats.rays++;
  const hit = closestHit(scene, root, ray);
  if (hit === null) {
    return lerp(scene.horizon, scene.zenith, Math.max(0, ray.dir.y));
  }
  const inside = dot(hit.normal, ray.dir) > 0;
  const normal = inside ? negate(hit.normal) : hit.normal;
  const color = shade(scene, root, ray, hit, normal, inside, depth);
  const emission = hit.material.emission;
  return emission === undefined ? color : add(color, emission);
}

// Reinhard's tone map, then gamma 2 through a square root, rounded to a byte.
function toByte(v: number): number {
  return Math.floor(Math.sqrt(v / (1 + v)) * 255 + 0.5);
}

// The image as red, green and blue bytes, row by row from the top, each pixel the mean of
// samples x samples rays jittered within it.
export function renderFrame(
  scene: Scene,
  root: Node,
  width: number,
  height: number,
  samples: number,
): number[] {
  const camera = scene.camera;
  const forward = normalize(sub(camera.target, camera.eye));
  const right = normalize(cross(forward, camera.up));
  const up = cross(right, forward);
  const halfWidth = (camera.height * width) / height;
  const weight = 1 / (samples * samples);
  const pixels: number[] = [];
  for (let py = 0; py < height; py++) {
    for (let px = 0; px < width; px++) {
      let sum = BLACK;
      for (let sy = 0; sy < samples; sy++) {
        for (let sx = 0; sx < samples; sx++) {
          const u = ((px + (sx + nextFloat()) / samples) / width) * 2 - 1;
          const v = 1 - ((py + (sy + nextFloat()) / samples) / height) * 2;
          const dir = normalize(
            addScaled(addScaled(forward, right, u * halfWidth), up, v * camera.height),
          );
          sum = add(sum, trace(scene, root, { origin: camera.eye, dir }, 0));
        }
      }
      const color = scale(sum, weight);
      pixels.push(toByte(color.x), toByte(color.y), toByte(color.z));
    }
  }
  return pixels;
}
