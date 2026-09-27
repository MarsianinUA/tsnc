// `try`, `catch` and `throw` are not supported in v1: return an error value instead. Both keywords
// are reported, so a rewrite sees every place it has to touch, and so is what stands inside them.
// expect: T2011 9:1
// expect: T2011 10:2
// expect: T2011 13:1
// expect: T2001 16:2
// expect: T2011 19:1
// expect: T2010 19:7
try {
	throw "broken";
} catch (error) {
}
try {
	console.log(1);
} catch (e) {
	var x = 1;
} finally {
}
throw new Error("x");
