// An import spells its path with the case the file and directory names have on disk. Windows and
// macOS would open the file anyway and Linux would not, so the spelling is refused on every OS. The
// first import is right and loads the module; the other two name the same file.
// expect: T4011 7:33 "`values.ts`"
// expect: T4011 8:33 "`modules`"
import { answer } from "./modules/values.ts";
import { answer as again } from "./modules/Values.ts";
import { answer as third } from "./Modules/values.ts";

console.log(answer, again, third);
