// `delete` is never supported: requirements 2.2, "Never".
// expect: T2006 4:1
const point = { x: 1, y: 2 };
delete point.x;
