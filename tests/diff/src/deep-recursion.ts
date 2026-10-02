// Node runs this function about 3800 frames deep before its stack ends, so 2800 leaves it room.
// The sixteen values live across the call take a frame of over 400 bytes at -o:none on Windows,
// where the default 1 MiB stack ended the program at 2430 frames.

function down(n: number, a: number): number {
	if (n === 0) {
		return a;
	}
	const x1 = (a * 3) % 7;
	const x2 = (a * 5) % 11;
	const x3 = (a * 7) % 13;
	const x4 = (a * 11) % 17;
	const x5 = (a * 13) % 19;
	const x6 = (a * 17) % 23;
	const x7 = (a * 19) % 29;
	const x8 = (a * 23) % 31;
	const x9 = (a * 29) % 37;
	const x10 = (a * 31) % 41;
	const x11 = (a * 37) % 43;
	const x12 = (a * 41) % 47;
	const x13 = (a * 43) % 53;
	const x14 = (a * 47) % 59;
	const x15 = (a * 53) % 61;
	const x16 = (a * 59) % 67;
	const r = down(n - 1, (a + 1) % 101);
	const left = x1 * x2 + x3 * x4 + x5 * x6 + x7 * x8;
	const right = x9 * x10 + x11 * x12 + x13 * x14 + x15 * x16;
	return (r + left + right) % 1000;
}

console.log(down(2800, 1));
