// `as` to a narrower union tests membership: a number and a circle pass and stay what they are,
// and a string, a member of neither, fails where Node prints it.
// stdout: 1
// stdout: { radius: 2 }
// stderr: error: type assertion failed at tests/expect/type-assertion-union.ts:13:9
// exit: 1

interface Circle {
	radius: number;
}

function pick(value: number | string | Circle): number | Circle {
	return value as number | Circle;
}

console.log(pick(1));
console.log(pick({ radius: 2 }));
console.log(pick("two"));
