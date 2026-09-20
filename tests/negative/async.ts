// `async` and `await` are not supported in v1: the calls are synchronous.
// expect: T2012 3:1
async function load(): Promise<number> {
	return 1;
}
