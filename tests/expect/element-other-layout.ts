// An array of objects flows into an array of a union as itself (requirements 3.6), so a push
// through the wide type can leave an object of another layout. The read through the narrow type
// tests the layout and fails, where Node prints undefined.
// stdout: 1
// stderr: error: an element holds a value its declared type does not allow at tests/expect/element-other-layout.ts:21:13
// exit: 1

interface Disc {
  kind: "disc";
  r: number;
}
interface Square {
  kind: "square";
  side: number;
}

const discs: Disc[] = [{ kind: "disc", r: 1 }];
const shapes: (Disc | Square)[] = discs;
console.log(discs[0].r);
shapes.push({ kind: "square", side: 2 });
console.log(discs[1].r);
