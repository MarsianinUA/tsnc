import { makeA } from "./a";
import { makeB } from "./b";

const b = makeB(null);
const a = makeA(b);
console.log(a.tag, b.tag);
