// A `readonly` field is written when the object is made and never again.
// The slot is part of the layout, so there is no second way in.
// expect: T3014 8:5
interface Box {
	readonly size: number;
}
const box: Box = { size: 1 };
box.size = 2;
