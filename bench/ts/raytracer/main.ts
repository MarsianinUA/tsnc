// A ray tracer over the modules beside this file: it parses a scene from text, builds meshes and
// a BVH over them, and renders a few frames of a moving lamp with shadows, reflection, refraction
// and textures from closures over Perlin noise.
//
// It takes only exactly rounded arithmetic (+ - * /, sqrt, floor, min, max), so that Node, tsnc and
// the Go twin print the same digits: sin, pow and exp differ in the last bit between V8, the C
// library and Go. So the camera takes the height of its image plane instead of an angle, and powers
// are products.
import { buildBvh } from "./bvh.ts";
import { initNoise } from "./noise.ts";
import { parseScene } from "./parse.ts";
import { renderFrame } from "./render.ts";
import { checksum, histogram, preview } from "./report.ts";
import { reseed } from "./rng.ts";
import { SCENE } from "./scene.ts";
import { sphere } from "./shapes.ts";
import { stats } from "./stats.ts";
import { addScaled } from "./vec.ts";

const WIDTH = 128;
const HEIGHT = 96;
const SAMPLES = 2;
const FRAMES = 3;

reseed(2026);
initNoise();
const scene = parseScene(SCENE);
console.log(
  `scene: ${scene.materials.length} materials, ${scene.solids.length} solids, ${scene.movers.length} moving, ${scene.planes.length} planes, ${scene.lights.length} lights`,
);

let total = 0;
let last: number[] = [];
for (let frame = 0; frame < FRAMES; frame++) {
  const solids = scene.solids.slice();
  for (const mover of scene.movers) {
    const s = mover.sphere;
    solids.push(sphere(addScaled(s.center, mover.velocity, frame), s.radius, s.material));
  }
  stats.nodes = 0;
  const root = buildBvh(solids);
  const pixels = renderFrame(scene, root, WIDTH, HEIGHT, SAMPLES);
  const sum = checksum(pixels);
  console.log(`frame ${frame}: ${stats.nodes} nodes, checksum ${sum}`);
  total = (total * 31 + sum) % 1000000007;
  last = pixels;
}

console.log(`histogram: ${histogram(last, 8).join(" ")}`);
for (const line of preview(last, WIDTH, HEIGHT, 32, 16)) {
  console.log(line);
}
console.log(
  `rays: ${stats.rays}, shadow rays: ${stats.shadowRays}, box tests: ${stats.boxTests}, shape tests: ${stats.shapeTests}`,
);
console.log(`checksum: ${total}`);
