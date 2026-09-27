// Destructuring is not supported in v1: read each field on its own. A declaration that loses its
// names to it declares nothing, so two of them do not collide. Parameters, loop variables,
// assignments and defaults are refused alike.
// expect: T2014 12:7
// expect: T2014 13:7
// expect: T2014 14:15
// expect: T2014 16:12
// expect: T2014 20:1
// expect: T2014 21:2
// expect: T2014 21:6
const point = { x: 1, y: 2 };
const { x, y } = point;
const { z } = point;
function head([first]: number[]): void {}
const pairs = [[1, 2]];
for (const [k, v] of pairs) {
}
let a = 1;
let b = 2;
[a, b] = [b, a];
({ x = 1 } = point);
