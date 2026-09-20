// A module exports a name once. Exporting two declarations under one name would leave an importer
// with no way to say which it means.
// expect: T4002 6:27
const first: number = 1;
const second: number = 2;
export { first, second as first };
