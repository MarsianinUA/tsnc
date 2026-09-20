// The other half of the ring that import-cycle.ts closes. Both modules run code as they load,
// which is what turns the ring from a shape the compiler allows into a mistake.

import { step } from "../import-cycle.ts";

export const total: number = step + 1;

console.log(total);
