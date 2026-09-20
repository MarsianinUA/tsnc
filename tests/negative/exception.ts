// `try`, `catch` and `throw` are not supported in v1: return an error value instead. Both keywords
// are reported, so a rewrite sees every place it has to touch.
// expect: T2011 5:1
// expect: T2011 6:2
try {
	throw "broken";
} catch (error) {
}
