// A specifier that names something the compiler cannot read says so, rather than answering that
// the module is missing. Here it names a directory, which every OS reports under its own name.
// expect: T4006 4:24
import { answer } from "./modules/unreadable.ts";

console.log(answer);
