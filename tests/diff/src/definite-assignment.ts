// A `let` declared without a value may be read wherever every path to the read wrote it first
// (requirements 5): on both arms of an `if`, in every case of a `switch` that covers the union,
// before a loop that reads it. A plain write is no read, and an arrow made after the write reads
// what the variable holds when it runs.

function size(c: boolean): number {
	let s: string;
	if (c) {
		s = "a";
	} else {
		s = "bb";
	}
	return s.length;
}

function name(k: "a" | "b"): string {
	let s: string;
	switch (k) {
		case "a":
			s = "first";
			break;
		case "b":
			s = "second";
			break;
	}
	return s;
}

function total(xs: number[]): number {
	let t: number;
	t = 0;
	for (const x of xs) {
		t = t + x;
	}
	return t;
}

function run(): string {
	let s: string;
	s = "a";
	return s;
}

let timer: number;
timer = 0;
const step = (): number => timer + 1;

console.log(size(true), size(false), name("a"), name("b"));
console.log(total([1, 2, 3]), total([]), run(), step());
timer = 5;
console.log(step());
