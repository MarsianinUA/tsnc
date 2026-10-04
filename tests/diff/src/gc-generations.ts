// Cells that live through collections take cells made after them (requirements 6). A minor
// collection traces the young cells and the old ones the write barrier remembered, so a store of
// each kind into an old cell has to reach it: a reference field, a tagged field, a field of a new
// cell after an allocation, an element by index and by push, an array that grows past its buffer,
// a variable a closure captured, and the stores the runtime makes for split and sort. A string
// that doubles makes the normal mode collect often, with full collections among the minor ones,
// while the stress mode stays quick.

interface Node {
  next: Node | null;
  label: string;
  value: number | string;
}

function keeper(): (node: Node) => number {
  let last: Node | null = null;
  return (node: Node): number => {
    const before = last === null ? 0 : last.label.length;
    last = node;
    return before;
  };
}

function chainLength(node: Node | null): number {
  let count = 0;
  while (node !== null) {
    count++;
    node = node.next;
  }
  return count;
}

const head: Node = { next: null, label: "head", value: 0 };
const nodes: Node[] = [];
const mixed: (number | string)[] = [0, 0, 0, 0, 0];
const lists: string[][] = [[], [], []];
const keep = keeper();
let text = "x";
let total = 0;

for (let round = 0; round < 240; round++) {
  text = text.length > 200000 ? "x" + round : text + text;
  const node: Node = { next: null, label: "n" + round, value: round % 2 === 0 ? round : "s" + round };
  node.label = node.label + text.slice(0, 1);
  node.next = head.next;
  head.next = node;
  head.value = "v" + round;
  head.label = text.slice(0, 3) + round;
  nodes.push(node);
  nodes[round % nodes.length] = { next: null, label: "m" + round, value: text.length };
  mixed[round % mixed.length] = round % 3 === 0 ? round : "t" + round;
  lists[round % lists.length] = ("a b c " + round).split(" ");
  total += keep({ next: null, label: text.slice(0, round % 5), value: round });
  if (round % 60 === 59) {
    nodes.sort((a, b) => (a.label < b.label ? -1 : a.label > b.label ? 1 : 0));
    total += nodes.length;
  }
}

let values = 0;
for (const node of nodes) {
  values += typeof node.value === "number" ? node.value % 1000 : node.value.length;
}

console.log(chainLength(head), head.label, head.value, total, values);
console.log(nodes[0].label, nodes[nodes.length - 1].label, mixed.join(","));
console.log(lists.map((list) => list.join("+")).join(" "));
