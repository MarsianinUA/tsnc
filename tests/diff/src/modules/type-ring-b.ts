// Only a type leaves this module, so Node never loads it and this line never appears.
import { first } from "./type-ring-a.ts";

console.log("type-ring-b loads", first);

export interface Later {
  name: string;
}
