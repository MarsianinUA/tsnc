// `x!` on an object that turns out null fails as it does on undefined, before the field is read,
// where Node throws a TypeError for reading a field of null.
// stdout: 2
// stderr: error: non-null assertion failed at tests/expect/non-null-object.ts:12:9
// exit: 1

interface Circle {
	radius: number;
}

function radius(circle: Circle | null): number {
	return circle!.radius;
}

console.log(radius({ radius: 2 }));
console.log(radius(null));
