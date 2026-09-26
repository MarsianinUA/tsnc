// join takes "," for a separator it is not given and for one that is undefined when it runs.

function separator(use: boolean): string | undefined {
	return use ? " - " : undefined;
}

const numbers = [1, 2, 3];
console.log(numbers.join(separator(false)));
console.log(numbers.join(separator(true)));
console.log(numbers.join(undefined));
console.log(numbers.join());
console.log(["a", "b"].join(""));
