// A ring of modules is allowed while none of them runs anything as it loads. Both halves of this
// one print, so whichever goes first reads a value the other has not produced yet. Requirements 7.
// expect: T4007 4:23
import { total } from "./modules/ring.ts";

export const step: number = 1;

console.log(total);
