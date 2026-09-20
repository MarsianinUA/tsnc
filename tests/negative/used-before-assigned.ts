// A `let` written with a type and no initializer holds nothing until something assigns to it. Only
// one of the two paths here does, so the read below the branch can find the variable empty. tsnc
// emits no runtime check behind such a read, so the value would be garbage rather than an error.
// expect: T3025 10:9
function size(flag: boolean): number {
	let text: string;
	if (flag) {
		text = "a";
	}
	return text.length;
}
