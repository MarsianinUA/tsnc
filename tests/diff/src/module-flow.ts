// Reads narrowed through the top level of another module, asked for before that module is
// checked.
import { describe, label, name } from "./modules/mode.ts";

const shown: string = label;
console.log(name, shown.length, describe());
