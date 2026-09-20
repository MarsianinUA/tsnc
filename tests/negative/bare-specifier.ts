// Only relative paths are supported: tsnc reads no node_modules, so a package name never names a
// file. Requirements 7.
// expect: T4005 4:24
import { answer } from "values";

console.log(answer);
