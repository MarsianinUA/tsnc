// A module that declares nothing and passes on what geometry declares. A re-export imports the
// module it names, so geometry runs first, and this line shows the order.
console.log("relay loads");

export { scale } from "./geometry.ts";
export type { Point } from "./geometry.ts";
