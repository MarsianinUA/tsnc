// A function may name a `let` or `const` declared below it, as long as it runs after the
// declaration has: each read here is checked when it runs, and every check passes.

function describe(): string {
	return `${label}: ${count} ${point.x} ${double(count)} ${typeof count}`;
}

const label = "point";
let count = 2;
const point = { x: 3 };
const double = (n: number): number => n * 2;
console.log(describe());
count = 5;
console.log(describe());

function counter(): () => number {
	const next = (): number => {
		total += step;
		return total;
	};
	let total = 0;
	const step = 10;
	return next;
}

const tick = counter();
console.log(tick(), tick());

let flag: boolean | undefined;
function readFlag(): string {
	return flag === undefined ? "unset" : String(flag);
}
console.log(readFlag());
flag = true;
console.log(readFlag());
