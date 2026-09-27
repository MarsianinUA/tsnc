// One half of a ring (requirements 7): ring-a and ring-b import functions from each other. Neither
// runs anything as it loads, so neither can read a value the other has not made yet; the calls
// cross the ring from function bodies, which run once both have loaded.
import type { Tag } from "./ring-b.ts";
import { tag } from "./ring-b.ts";

export interface Entry {
  tag: Tag;
}

export function make(): Entry {
  return { tag: tag() };
}
