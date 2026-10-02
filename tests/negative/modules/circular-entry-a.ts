import type { CircleB } from "./circular-entry-b.ts";
import type { CircleC } from "./circular-entry-c.ts";

export type CircleA = CircleB | CircleC;
