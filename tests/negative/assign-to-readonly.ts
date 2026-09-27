// A `readonly` field is written when the object is made and never again.
// The slot is part of the layout, so there is no second way in. The lib's own fields are no
// different: `process.argv` is readonly.
// expect: T3014 10:5
// expect: T3014 11:9
interface Box {
	readonly size: number;
}
const box: Box = { size: 1 };
box.size = 2;
process.argv = [];
