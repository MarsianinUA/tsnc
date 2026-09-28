// A narrow object flows into a wider type as itself (requirements 3.3), so a write of null through
// the wide type shows through the narrow one, whose field holds a present box. The read through the
// narrow type tests the pointer and fails, where Node throws a TypeError reading a field of null.
// stdout: 1
// stderr: error: a field holds a value its declared type does not allow at tests/expect/field-null.ts:24:13
// exit: 1

interface Box {
	n: number;
}

interface Holder {
	box: Box;
}

interface Loose {
	box: Box | null;
}

const holder: Holder = { box: { n: 1 } };
const loose: Loose = holder;
console.log(holder.box.n);
loose.box = null;
console.log(holder.box.n);
