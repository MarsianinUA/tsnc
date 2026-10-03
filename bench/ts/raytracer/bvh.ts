// A bounding volume hierarchy: split at the median centroid along the longest axis, then walk it
// with a stack, nearer child first.
import type { Box, Hit, Solid } from "./shapes.ts";
import { bounds, centroid, intersect } from "./shapes.ts";
import type { Ray, Vec } from "./vec.ts";
import { component, maxVec, minVec, sub, vec } from "./vec.ts";
import { stats } from "./stats.ts";

const LEAF_SIZE = 4;

// A leaf has no children and holds shapes; an inner node holds none.
export interface Node {
  readonly box: Box;
  readonly axis: number;
  readonly left: Node | null;
  readonly right: Node | null;
  readonly shapes: Solid[];
}

interface Entry {
  readonly shape: Solid;
  readonly box: Box;
  readonly center: Vec;
  readonly index: number;
}

export function buildBvh(shapes: Solid[]): Node {
  const entries = shapes.map((shape, index): Entry => ({
    shape,
    box: bounds(shape),
    center: centroid(shape),
    index,
  }));
  return build(entries);
}

function build(entries: Entry[]): Node {
  stats.nodes++;
  let min = entries[0].box.min;
  let max = entries[0].box.max;
  let low = entries[0].center;
  let high = entries[0].center;
  for (const entry of entries) {
    min = minVec(min, entry.box.min);
    max = maxVec(max, entry.box.max);
    low = minVec(low, entry.center);
    high = maxVec(high, entry.center);
  }
  const box = { min, max };
  if (entries.length <= LEAF_SIZE) {
    return { box, axis: 0, left: null, right: null, shapes: entries.map((entry) => entry.shape) };
  }

  const extent = sub(high, low);
  const axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : extent.y >= extent.z ? 1 : 2;
  const sorted = entries.slice();
  sorted.sort((p, q) => {
    const d = component(p.center, axis) - component(q.center, axis);
    return d !== 0 ? d : p.index - q.index;
  });
  const mid = Math.floor(sorted.length / 2);
  const left = build(sorted.slice(0, mid));
  const right = build(sorted.slice(mid));
  return { box, axis, left, right, shapes: [] };
}

// The slab test: inv holds 1 / the ray's direction, so an axis the ray runs along gives infinities.
function enters(box: Box, origin: Vec, inv: Vec, limit: number): boolean {
  stats.boxTests++;
  const x0 = (box.min.x - origin.x) * inv.x;
  const x1 = (box.max.x - origin.x) * inv.x;
  let near = Math.min(x0, x1);
  let far = Math.max(x0, x1);
  const y0 = (box.min.y - origin.y) * inv.y;
  const y1 = (box.max.y - origin.y) * inv.y;
  near = Math.max(near, Math.min(y0, y1));
  far = Math.min(far, Math.max(y0, y1));
  const z0 = (box.min.z - origin.z) * inv.z;
  const z1 = (box.max.z - origin.z) * inv.z;
  near = Math.max(near, Math.min(z0, z1));
  far = Math.min(far, Math.max(z0, z1));
  return near <= far && far > 0 && near < limit;
}

function inverse(dir: Vec): Vec {
  return vec(1 / dir.x, 1 / dir.y, 1 / dir.z);
}

export function closest(root: Node, ray: Ray, tMax: number): Hit | null {
  const inv = inverse(ray.dir);
  const stack: Node[] = [root];
  let best: Hit | null = null;
  let limit = tMax;
  let node = stack.pop();
  while (node !== undefined) {
    if (enters(node.box, ray.origin, inv, limit)) {
      if (node.left === null || node.right === null) {
        for (const shape of node.shapes) {
          const hit = intersect(shape, ray, limit);
          if (hit !== null) {
            best = hit;
            limit = hit.t;
          }
        }
      } else if (component(ray.dir, node.axis) < 0) {
        stack.push(node.left);
        stack.push(node.right);
      } else {
        stack.push(node.right);
        stack.push(node.left);
      }
    }
    node = stack.pop();
  }
  return best;
}

// Whether anything lies on the ray before distance: a shadow needs any hit, not the nearest.
export function occluded(root: Node, ray: Ray, distance: number): boolean {
  const inv = inverse(ray.dir);
  const stack: Node[] = [root];
  let node = stack.pop();
  while (node !== undefined) {
    if (enters(node.box, ray.origin, inv, distance)) {
      if (node.left === null || node.right === null) {
        for (const shape of node.shapes) {
          if (intersect(shape, ray, distance) !== null) {
            return true;
          }
        }
      } else {
        stack.push(node.left);
        stack.push(node.right);
      }
    }
    node = stack.pop();
  }
  return false;
}
