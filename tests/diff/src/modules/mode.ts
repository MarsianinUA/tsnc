// describe is checked before the write below it and asks for name and label then: both are
// narrowed by the write all the same.
export let mode: string | undefined;

export function describe(): string {
	return `${name} and ${label}`;
}

mode = "fast";

export const name: string = mode;
export const label = mode;
