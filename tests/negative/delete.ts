// `delete` is never supported: requirements 2.2, "Never".
// expect: T2006 5:1
// expect: T2006 7:2
const point = { x: 1, y: 2 };
delete point.x;
function drop(): void {
	delete point.x;
}
