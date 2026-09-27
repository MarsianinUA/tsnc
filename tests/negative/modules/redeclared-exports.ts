// The exports redeclared-name.ts imports. Each repeated name is one mistake, reported here, and
// the importer shows which declaration the export table kept: the first `exported`, whose result
// is a number, and no `lost` at all, since the function that would export it repeats a `let`.

export function exported(): number {
	return 1;
}
export function exported(): string {
	return "a";
}

let lost = 1;
export function lost(): void {}
