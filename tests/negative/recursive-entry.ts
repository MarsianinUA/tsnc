// A loop is one mistake wherever a checker enters it, so it is reported once, at the member
// declared first, under every split of the program. Two loops over three modules share `a`, and
// four functions of one module call each other in two loops that share figureB. The uses below
// reach each loop at another member than the walk of its own module does.
// expect: T3010 modules/recursive-entry-a.ts:4:17
// expect: T3010 modules/recursive-entry-figure.ts:1:17
import { a } from "./modules/recursive-entry-a.ts";
import { c } from "./modules/recursive-entry-c.ts";
import { figureD } from "./modules/recursive-entry-figure.ts";

console.log(c(1), a(2), figureD(3));
