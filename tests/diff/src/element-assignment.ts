// A compound assignment to an element reads it, runs the right side, and then writes at the index
// against the length the array has by then. Here the right side takes the last element away, so
// the write appends it again, as in Node.

const a = [1, 2, 3];
function shrink(): number {
	a.pop();
	return 10;
}
a[2] += shrink();
console.log(a);

const b = [2, 4, 6];
function shorten(): number {
	b.pop();
	return 3;
}
b[2] *= shorten();
console.log(b);

const c = [5, 6];
c[1]++;
--c[0];
c[c.length] = 9;
console.log(c);
