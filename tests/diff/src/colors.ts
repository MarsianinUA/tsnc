// env: FORCE_COLOR=1 NO_COLOR= NODE_DISABLE_COLORS=
//
// Colors (requirements 3.9): with FORCE_COLOR set, Node colors what util.inspect prints even
// through a pipe, which is how the runner sees it. The line above sets it for both runs; the two
// empty variables keep Node from warning that they are ignored, should the machine set them.

function maybe(flag: boolean): number | undefined {
  return flag ? 1 : undefined;
}

// A bare string is written as it is; every other value takes the color of its kind.
console.log("text", 1, -0, true, null, undefined, maybe(true), maybe(false));
console.error(false, NaN);

// %O and %o color what they inspect, %s and the number specifiers never do.
console.log("%O %o %s %d %i %f", "quoted", 2, 3, 4, 5, 6);
console.log("%O", "a line that is long enough to be broken\nafter its first line end, and every piece in color");

// Inside an array or an object each value takes the color of its kind, and a reference the color
// of a function. The codes take no column when numbers group.
function f(): void {}

const thirty: number[] = [];
for (let i = 1; i <= 30; i++) {
  thirty.push(i);
}
const ring: unknown[] = [1];
ring.push(ring);
console.log("%s %d %O %o", 1, 2, 3, [4]);
console.log([1, "a", null, undefined, true, f, { k: [2] }]);
console.log(thirty);
console.log(ring);
