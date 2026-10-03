// binary-trees: many short-lived trees next to one that lives through the run, so the collector
// works on garbage while a large live set stays reachable.
interface Tree {
  left: Tree | null;
  right: Tree | null;
}

const MAX_DEPTH = 17;

function build(depth: number): Tree {
  if (depth === 0) {
    return { left: null, right: null };
  }
  return { left: build(depth - 1), right: build(depth - 1) };
}

function check(tree: Tree | null): number {
  if (tree === null) {
    return 0;
  }
  return 1 + check(tree.left) + check(tree.right);
}

const longLived = build(MAX_DEPTH);
for (let depth = 4; depth <= MAX_DEPTH; depth += 2) {
  const iterations = 2 ** (MAX_DEPTH - depth + 4);
  let nodes = 0;
  for (let i = 0; i < iterations; i++) {
    nodes += check(build(depth));
  }
  console.log(iterations, depth, nodes);
}
console.log(MAX_DEPTH, check(longLived));
