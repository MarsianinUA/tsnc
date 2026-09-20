// Generics of one's own arrive in v2. The built-in `Array<T>` and `map<U>` stay, because the lib
// file is the one place a type parameter may be written.
// expect: T2023 4:16
function first<T>(items: T[]): T {
	return items[0];
}
