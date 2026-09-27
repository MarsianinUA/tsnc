// Narrowing along the flow of a function (requirements 2.2, 5): each read takes the type that the
// conditions on its path proved, through `!`, `&&`, `||` and `??`, across a write to another name,
// into an arrow made inside the test, and for the variable of a `for...of`. The annotated bindings
// pin the narrowed type, since a wider one would not compile, and the values are printed so that
// the narrowed reads run too.

function show(name: string | undefined): string {
	if (!name) {
		return "none";
	}
	const known: string = name;
	return known;
}

function size(s: string | undefined): number {
	if (s !== undefined && s.length > 0) {
		return s.length;
	}
	return 0;
}

function missing(x: undefined): string {
	return "missing";
}

// The right side of `??` runs only where the left one was null or undefined.
function coalesce(s: string | undefined): string {
	return s ?? missing(s);
}

// The left side of `||` survives only where it is truthy, so undefined is gone from the result.
function orNone(name: string | undefined): string {
	const shown: string = name || "none";
	return shown;
}

// The reads in the first branch are numbers, so `+=` adds; each write is measured against the
// declared type, or the narrowing would forbid the write that ends it.
function rewrite(v: string | number): string {
	if (typeof v === "number") {
		v += 1;
		console.log("added", v);
		v = "a";
	}
	if (typeof v === "number") {
		v = "b";
	}
	return v;
}

interface Box {
	v: number | undefined;
}

// A write to another name leaves what the test proved about the field.
function field(b: Box, k: number): number {
	if (b.v !== undefined) {
		k = 1;
		const n: number = b.v;
		return n + k;
	}
	return k;
}

function measure(v: string | number): number {
	if (typeof v === "string") {
		const get = (): number => v.length;
		return get();
	}
	return v;
}

console.log(show(undefined), show(""), show("ab"));
console.log(size(undefined), size(""), size("abc"));
console.log(coalesce(undefined), coalesce("given"), coalesce(""));
console.log(orNone(undefined), orNone(""), orNone("x"));
console.log(rewrite(1), rewrite("s"));
console.log(field({ v: 5 }, 10), field({ v: undefined }, 10));
console.log(measure("four"), measure(7));

const mixed: (number | string)[] = [1, "ab", 3, "cde"];
for (const item of mixed) {
	if (typeof item === "string") {
		const text: string = item;
		console.log("string", text.length);
	} else {
		const count: number = item;
		console.log("number", count * 2);
	}
}
