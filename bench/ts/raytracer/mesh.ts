import type { Material } from "./material.ts";
import type { Triangle } from "./shapes.ts";
import { triangle } from "./shapes.ts";
import type { Vec } from "./vec.ts";
import { add, addScaled, cross, normalize, sub, vec } from "./vec.ts";
import { fbm } from "./noise.ts";

// The 20 faces of an icosahedron, three indices into its 12 points each.
const ICOSAHEDRON = [
  0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
  3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
];

// The six faces of a box, four indices into its corners each, counterclockwise seen from outside.
// Bit 0 of a corner picks max x, bit 1 max y, bit 2 max z.
const QUADS = [0, 2, 3, 1, 4, 5, 7, 6, 0, 1, 5, 4, 2, 6, 7, 3, 0, 4, 6, 2, 1, 3, 7, 5];

// An open-addressing table from an edge to the point that splits it, so that the two faces along
// an edge share the new point. A key of -1 marks an empty slot.
interface EdgeTable {
  keys: number[];
  values: number[];
  mask: number;
  count: number;
}

function makeTable(size: number): EdgeTable {
  const keys: number[] = [];
  const values: number[] = [];
  for (let i = 0; i < size; i++) {
    keys.push(-1);
    values.push(0);
  }
  return { keys, values, mask: size - 1, count: 0 };
}

function slotOf(table: EdgeTable, key: number): number {
  let slot = (key * 7919) & table.mask;
  while (table.keys[slot] !== -1 && table.keys[slot] !== key) {
    slot = (slot + 1) & table.mask;
  }
  return slot;
}

function grow(table: EdgeTable): void {
  const keys = table.keys;
  const values = table.values;
  const bigger = makeTable(keys.length * 2);
  table.keys = bigger.keys;
  table.values = bigger.values;
  table.mask = bigger.mask;
  for (let i = 0; i < keys.length; i++) {
    if (keys[i] !== -1) {
      const slot = slotOf(table, keys[i]);
      table.keys[slot] = keys[i];
      table.values[slot] = values[i];
    }
  }
}

function midpoint(table: EdgeTable, points: Vec[], i: number, j: number): number {
  const key = i < j ? i * 65536 + j : j * 65536 + i;
  const slot = slotOf(table, key);
  if (table.keys[slot] === key) {
    return table.values[slot];
  }
  const index = points.length;
  points.push(normalize(add(points[i], points[j])));
  table.keys[slot] = key;
  table.values[slot] = index;
  table.count++;
  if (table.count * 2 > table.keys.length) {
    grow(table);
  }
  return index;
}

// An icosahedron with each face split in four `depth` times and pushed out onto the sphere; the
// normal at a point is its direction from the center, so the sphere shades smooth.
export function icosphere(
  center: Vec,
  radius: number,
  depth: number,
  material: Material,
): Triangle[] {
  const t = (1 + Math.sqrt(5)) / 2;
  const points = [
    vec(-1, t, 0),
    vec(1, t, 0),
    vec(-1, -t, 0),
    vec(1, -t, 0),
    vec(0, -1, t),
    vec(0, 1, t),
    vec(0, -1, -t),
    vec(0, 1, -t),
    vec(t, 0, -1),
    vec(t, 0, 1),
    vec(-t, 0, -1),
    vec(-t, 0, 1),
  ].map(normalize);
  const table = makeTable(64);
  let faces = ICOSAHEDRON;
  for (let level = 0; level < depth; level++) {
    const next: number[] = [];
    for (let f = 0; f < faces.length; f += 3) {
      const a = faces[f];
      const b = faces[f + 1];
      const c = faces[f + 2];
      const ab = midpoint(table, points, a, b);
      const bc = midpoint(table, points, b, c);
      const ca = midpoint(table, points, c, a);
      next.push(a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca);
    }
    faces = next;
  }

  const triangles: Triangle[] = [];
  for (let f = 0; f < faces.length; f += 3) {
    const na = points[faces[f]];
    const nb = points[faces[f + 1]];
    const nc = points[faces[f + 2]];
    const a = addScaled(center, na, radius);
    const b = addScaled(center, nb, radius);
    const c = addScaled(center, nc, radius);
    triangles.push(triangle(a, b, c, na, nb, nc, material));
  }
  return triangles;
}

export function box(min: Vec, max: Vec, material: Material): Triangle[] {
  const corners: Vec[] = [];
  for (let i = 0; i < 8; i++) {
    const x = (i & 1) === 0 ? min.x : max.x;
    const y = (i & 2) === 0 ? min.y : max.y;
    const z = (i & 4) === 0 ? min.z : max.z;
    corners.push(vec(x, y, z));
  }
  const triangles: Triangle[] = [];
  for (let f = 0; f < QUADS.length; f += 4) {
    const a = corners[QUADS[f]];
    const b = corners[QUADS[f + 1]];
    const c = corners[QUADS[f + 2]];
    const d = corners[QUADS[f + 3]];
    const n = normalize(cross(sub(b, a), sub(c, a)));
    triangles.push(triangle(a, b, c, n, n, n, material));
    triangles.push(triangle(a, c, d, n, n, n, material));
  }
  return triangles;
}

// A height field of cells x cells squares from origin, size wide along x and z, raised by fractal
// noise. The normal at a point sums the normals of the faces around it, weighted by their area.
export function terrain(
  origin: Vec,
  size: number,
  cells: number,
  height: number,
  material: Material,
): Triangle[] {
  const side = cells + 1;
  const points: Vec[] = [];
  const sums: Vec[] = [];
  for (let j = 0; j < side; j++) {
    for (let i = 0; i < side; i++) {
      const x = origin.x + (i * size) / cells;
      const z = origin.z + (j * size) / cells;
      const y = origin.y + height * fbm(vec(x * 0.2, 0.37, z * 0.2), 5);
      points.push(vec(x, y, z));
      sums.push(vec(0, 0, 0));
    }
  }

  const faces: number[] = [];
  for (let j = 0; j < cells; j++) {
    for (let i = 0; i < cells; i++) {
      const p = j * side + i;
      faces.push(p, p + side, p + 1, p + 1, p + side, p + side + 1);
    }
  }
  for (let f = 0; f < faces.length; f += 3) {
    const a = faces[f];
    const b = faces[f + 1];
    const c = faces[f + 2];
    const n = cross(sub(points[b], points[a]), sub(points[c], points[a]));
    sums[a] = add(sums[a], n);
    sums[b] = add(sums[b], n);
    sums[c] = add(sums[c], n);
  }

  const triangles: Triangle[] = [];
  for (let f = 0; f < faces.length; f += 3) {
    const a = faces[f];
    const b = faces[f + 1];
    const c = faces[f + 2];
    triangles.push(
      triangle(
        points[a],
        points[b],
        points[c],
        normalize(sums[a]),
        normalize(sums[b]),
        normalize(sums[c]),
        material,
      ),
    );
  }
  return triangles;
}
