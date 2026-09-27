// `async` and `await` are not supported in v1: the calls are synchronous. Each keyword is
// reported where it stands, in a body, in a loop header and on an arrow.
// expect: T2012 14:1
// expect: T2012 15:2
// expect: T2012 18:5
// expect: T2012 20:1
// expect: T2012 21:5
// expect: T2012 22:5
const xs: number[] = [1, 2];
function run(callback: (x: number) => number): void {}
function pause(): number {
	return 0;
}
async function load(): Promise<number> {
	await pause();
	return 1;
}
for await (const x of xs) {
}
await pause();
run(async () => 1);
run(async x => 1);
