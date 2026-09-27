// A narrow object flows into a wider type as itself (requirements 3.3), so a write through the
// wide type can leave a value the narrow one does not allow. The read through the narrow type
// tests the tag and fails, where Node prints the string.
// stdout: 1
// stderr: error: a field holds a value its declared type does not allow at tests/expect/field-other-kind.ts:20:13
// exit: 1

interface Size {
	width: number;
}

interface Measure {
	width: number | string;
}

const size: Size = { width: 1 };
const measure: Measure = size;
console.log(size.width);
measure.width = "wide";
console.log(size.width);
