// A generic declaration of one's own is read once, in its own module, so a mistake inside it is
// reported once however many uses instantiate it.
// expect: T2023 modules/generic-members.ts:1:22
// expect: T4008 modules/generic-members.ts:2:5
import type { Box } from "./modules/generic-members.ts";

const one: Box<number> = { v: 1, w: 1 };
const two: Box<string> = { v: 1, w: "2" };
const three: Box<boolean> = { v: 1, w: true };
console.log(one, two, three);
