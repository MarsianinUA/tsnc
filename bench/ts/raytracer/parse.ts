// The scene format: one command per line, then positional words and key=value pairs; a vector is
// three numbers joined by commas, and # starts a comment.
//
//   material stone diffuse texture=marble color=0.9,0.88,0.85 scale=0.9
//   icosphere center=0,0.4,0 radius=1.4 depth=3 material=stone
import type { Kind, Material, Texture } from "./material.ts";
import { checker, marble, solid, strata, wood } from "./material.ts";
import { box, icosphere, terrain } from "./mesh.ts";
import type { Plane, Solid, Sphere, Triangle } from "./shapes.ts";
import { sphere } from "./shapes.ts";
import type { Vec } from "./vec.ts";
import { addScaled, normalize, vec } from "./vec.ts";

export interface Camera {
  readonly eye: Vec;
  readonly target: Vec;
  readonly up: Vec;
  // Half the height of the image plane at distance 1, which is the tangent of half the field of
  // view.
  readonly height: number;
}

export interface Light {
  readonly position: Vec;
  readonly color: Vec;
}

// A sphere that moves by velocity every frame.
export interface Mover {
  readonly sphere: Sphere;
  readonly velocity: Vec;
}

export interface Scene {
  camera: Camera;
  horizon: Vec;
  zenith: Vec;
  ambient: Vec;
  lights: Light[];
  materials: Material[];
  planes: Plane[];
  solids: Solid[];
  movers: Mover[];
}

interface Line {
  readonly number: number;
  readonly command: string;
  readonly words: string[];
  readonly keys: string[];
  readonly values: string[];
}

// Material names hashed into slots that hold the material's index + 1, 0 for an empty slot.
interface NameTable {
  readonly slots: number[];
  readonly materials: Material[];
}

const NAME_SLOTS = 64;

function fail(line: Line, message: string): never {
  console.error(`scene, line ${line.number}: ${message}`);
  process.exit(1);
}

function readLine(text: string, number: number): Line | null {
  const hash = text.indexOf("#");
  const content = (hash >= 0 ? text.slice(0, hash) : text).trim();
  if (content.length === 0) {
    return null;
  }
  const parts = content.split(" ").filter((part) => part.length > 0);
  const words: string[] = [];
  const keys: string[] = [];
  const values: string[] = [];
  for (let i = 1; i < parts.length; i++) {
    const equals = parts[i].indexOf("=");
    if (equals < 0) {
      words.push(parts[i]);
    } else {
      keys.push(parts[i].slice(0, equals));
      values.push(parts[i].slice(equals + 1));
    }
  }
  return { number, command: parts[0], words, keys, values };
}

function field(line: Line, key: string): string | null {
  const index = line.keys.indexOf(key);
  return index < 0 ? null : line.values[index];
}

function required(line: Line, key: string): string {
  const value = field(line, key);
  if (value === null) {
    fail(line, `${line.command} needs ${key}=`);
  }
  return value;
}

function word(line: Line, index: number, what: string): string {
  if (index >= line.words.length) {
    fail(line, `${line.command} needs a ${what}`);
  }
  return line.words[index];
}

function parseNumber(line: Line, text: string): number {
  const value = Number.parseFloat(text);
  // NaN is the one number not equal to itself.
  if (value !== value) {
    fail(line, `"${text}" is not a number`);
  }
  return value;
}

function parseVec(line: Line, text: string): Vec {
  const parts = text.split(",");
  if (parts.length !== 3) {
    fail(line, `"${text}" is not three numbers`);
  }
  return vec(parseNumber(line, parts[0]), parseNumber(line, parts[1]), parseNumber(line, parts[2]));
}

function numberOf(line: Line, key: string, fallback: number): number {
  const value = field(line, key);
  return value === null ? fallback : parseNumber(line, value);
}

function integerOf(line: Line, key: string, fallback: number): number {
  const value = numberOf(line, key, fallback);
  if (!Number.isInteger(value) || value < 0) {
    fail(line, `${key} must be a whole number`);
  }
  return value;
}

function vecOf(line: Line, key: string, fallback: Vec): Vec {
  const value = field(line, key);
  return value === null ? fallback : parseVec(line, value);
}

function requiredVec(line: Line, key: string): Vec {
  return parseVec(line, required(line, key));
}

function hashName(name: string): number {
  let hash = 0;
  for (let i = 0; i < name.length; i++) {
    hash = (hash * 31 + name.charCodeAt(i)) % 65521;
  }
  return hash;
}

// The slot of name, or of the empty slot where it would go.
function slotOf(table: NameTable, name: string): number {
  let slot = hashName(name) % NAME_SLOTS;
  while (table.slots[slot] !== 0 && table.materials[table.slots[slot] - 1].name !== name) {
    slot = (slot + 1) % NAME_SLOTS;
  }
  return slot;
}

function kindOf(line: Line, text: string): Kind {
  switch (text) {
    case "diffuse":
      return "diffuse";
    case "mirror":
      return "mirror";
    case "glass":
      return "glass";
    default:
      fail(line, `unknown material kind "${text}"`);
  }
}

function textureOf(line: Line): Texture {
  const color = vecOf(line, "color", vec(0.8, 0.8, 0.8));
  const kind = field(line, "texture") ?? "solid";
  switch (kind) {
    case "solid":
      return solid(color);
    case "checker":
      return checker(color, requiredVec(line, "color2"), numberOf(line, "scale", 1));
    case "marble":
      return marble(color, requiredVec(line, "color2"), numberOf(line, "scale", 1));
    case "wood":
      return wood(color, requiredVec(line, "color2"), numberOf(line, "scale", 1));
    case "strata":
      return strata(
        color,
        requiredVec(line, "color2"),
        numberOf(line, "from", 0),
        numberOf(line, "to", 1),
      );
    default:
      fail(line, `unknown texture "${kind}"`);
  }
}

function addMaterial(table: NameTable, line: Line): void {
  const name = word(line, 0, "name");
  const slot = slotOf(table, name);
  if (table.slots[slot] !== 0) {
    fail(line, `material ${name} is defined twice`);
  }
  if ((table.materials.length + 1) * 2 > NAME_SLOTS) {
    fail(line, "too many materials");
  }
  const emit = field(line, "emit");
  table.materials.push({
    name,
    kind: kindOf(line, word(line, 1, "kind")),
    texture: textureOf(line),
    specular: numberOf(line, "specular", 0),
    shininess: integerOf(line, "shininess", 1),
    reflectivity: numberOf(line, "reflect", 0),
    ior: numberOf(line, "ior", 1.5),
    emission: emit === null ? undefined : parseVec(line, emit),
  });
  table.slots[slot] = table.materials.length;
}

function materialOf(table: NameTable, line: Line): Material {
  const name = required(line, "material");
  const slot = slotOf(table, name);
  if (table.slots[slot] === 0) {
    fail(line, `no material ${name}`);
  }
  return table.materials[table.slots[slot] - 1];
}

function addSphere(scene: Scene, line: Line, s: Sphere): void {
  const move = field(line, "move");
  if (move === null) {
    scene.solids.push(s);
  } else {
    scene.movers.push({ sphere: s, velocity: parseVec(line, move) });
  }
}

function addAll(scene: Scene, triangles: Triangle[]): void {
  for (const t of triangles) {
    scene.solids.push(t);
  }
}

export function parseScene(source: string): Scene {
  const table: NameTable = { slots: [], materials: [] };
  for (let i = 0; i < NAME_SLOTS; i++) {
    table.slots.push(0);
  }
  const scene: Scene = {
    camera: { eye: vec(0, 0, 1), target: vec(0, 0, 0), up: vec(0, 1, 0), height: 0.5 },
    horizon: vec(1, 1, 1),
    zenith: vec(0.5, 0.7, 1),
    ambient: vec(0, 0, 0),
    lights: [],
    materials: table.materials,
    planes: [],
    solids: [],
    movers: [],
  };

  const lines = source.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = readLine(lines[i], i + 1);
    if (line === null) {
      continue;
    }
    switch (line.command) {
      case "camera":
        scene.camera = {
          eye: requiredVec(line, "eye"),
          target: requiredVec(line, "target"),
          up: vecOf(line, "up", vec(0, 1, 0)),
          height: numberOf(line, "height", 0.5),
        };
        break;
      case "sky":
        scene.horizon = requiredVec(line, "horizon");
        scene.zenith = requiredVec(line, "zenith");
        break;
      case "ambient":
        scene.ambient = parseVec(line, word(line, 0, "color"));
        break;
      case "light":
        scene.lights.push({ position: requiredVec(line, "at"), color: requiredVec(line, "color") });
        break;
      case "material":
        addMaterial(table, line);
        break;
      case "plane":
        scene.planes.push({
          kind: "plane",
          normal: normalize(requiredVec(line, "normal")),
          offset: numberOf(line, "offset", 0),
          material: materialOf(table, line),
        });
        break;
      case "sphere":
        addSphere(
          scene,
          line,
          sphere(requiredVec(line, "center"), numberOf(line, "radius", 1), materialOf(table, line)),
        );
        break;
      case "spheres": {
        const from = requiredVec(line, "from");
        const step = requiredVec(line, "step");
        const count = integerOf(line, "count", 1);
        const radius = numberOf(line, "radius", 1);
        const material = materialOf(table, line);
        for (let k = 0; k < count; k++) {
          addSphere(scene, line, sphere(addScaled(from, step, k), radius, material));
        }
        break;
      }
      case "icosphere":
        addAll(
          scene,
          icosphere(
            requiredVec(line, "center"),
            numberOf(line, "radius", 1),
            integerOf(line, "depth", 2),
            materialOf(table, line),
          ),
        );
        break;
      case "box":
        addAll(
          scene,
          box(requiredVec(line, "min"), requiredVec(line, "max"), materialOf(table, line)),
        );
        break;
      case "terrain":
        addAll(
          scene,
          terrain(
            requiredVec(line, "origin"),
            numberOf(line, "size", 10),
            integerOf(line, "cells", 8),
            numberOf(line, "height", 1),
            materialOf(table, line),
          ),
        );
        break;
      default:
        fail(line, `unknown command "${line.command}"`);
    }
  }
  return scene;
}
