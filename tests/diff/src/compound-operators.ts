// The compound assignments (requirements 2.2): `x op= y` reads the place, applies the operator and
// writes the answer back, and the expression is worth that answer. The bitwise ones convert both
// sides with ToInt32, or ToUint32 for `>>>=`, so their corners are those of the plain operators: a
// negative or fractional operand, a number past 2^32, a shift count past 31. The place is evaluated
// before the value, so `a[i] = (i = 5)` writes at the index the place saw.

// The elements of a literal run left to right, so each one sees the writes of those before it.
function arithmetic(a: number, b: number): number[] {
	let r = a;
	return [(r += b), (r -= 3 * b), (r *= b), (r /= 4), (r %= b), (r **= 2), (r %= -1), (r **= -1), r];
}

function remainders(a: number, b: number): number[] {
	let r = a;
	let z = -a;
	return [(r %= b), (z %= 2), (r /= 0), r];
}

function bits(a: number, b: number): number[] {
	let r = a;
	return [(r <<= b), (r >>= 1), (r >>>= 0), (r &= 0xff), (r |= 0x100), (r ^= 0x1ff), r];
}

console.log(arithmetic(7, 2), remainders(-7, 3), remainders(4, 3));
console.log(bits(-5.7, 33), bits(4294967297.9, 31), bits(NaN, 1));

let text = "a";
text += 1;
text += "b";
console.log(text);

interface Counter {
	value: number;
	label: string;
}

const counter: Counter = { value: 10, label: "n" };
counter.value -= 3;
counter.value <<= 2;
counter.value %= 5;
counter.label += "!";
counter.label += counter.value;
console.log(counter);

const cells = [2, 2, 3];
cells[0] **= 3;
cells[1] >>>= 1;
cells[2] ^= 7;
cells[1] |= 8;
console.log(cells);

function write(a: number[]): number {
	let i = 0;
	a[i] = (i = 5);
	return i;
}

const target = [1];
console.log(write(target), target);

const more = [10, 20];
let j = 0;
more[j] += (j = 1);
console.log(more, j);
