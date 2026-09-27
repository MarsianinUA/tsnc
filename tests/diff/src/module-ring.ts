// A ring of modules that only declare types and functions is allowed (requirements 7). The program
// stands outside the ring and calls across it.
import { make } from "./modules/ring-a.ts";
import { fresh, tagOf } from "./modules/ring-b.ts";

const early: "a" | "b" = tagOf(make());
console.log(early, fresh(), make());
