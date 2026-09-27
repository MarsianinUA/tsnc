// The other half of the ring. Tag is declared here, names the field of ring-a's Entry, and reads
// back here through it.
import type { Entry } from "./ring-a.ts";
import { make } from "./ring-a.ts";

export type Tag = "a" | "b";

export function tag(): Tag {
  return "a";
}

export function tagOf(entry: Entry): Tag {
  return entry.tag;
}

export function fresh(): Tag {
  return tagOf(make());
}
