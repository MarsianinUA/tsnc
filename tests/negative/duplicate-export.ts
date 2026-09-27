// A module exports a name once. Exporting two declarations under one name would leave an importer
// with no way to say which it means, and a re-export counts as one of the two. One name may still
// be exported once as a value and once as a type.
// expect: T4002 8:27
// expect: T4002 10:20
const first: number = 1;
const second: number = 2;
export { first, second as first };
export const shared: number = 3;
export { answer as shared } from "./modules/values.ts";
export interface Shape {
	size: number;
}
export const Shape: Shape = { size: 1 };
