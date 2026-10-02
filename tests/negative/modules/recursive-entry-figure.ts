export function figureA(n: number) {
	return figureB(n);
}
export function figureB(n: number) {
	return n > 0 ? figureC(n - 1) + figureD(n - 1) : 0;
}
export function figureC(n: number) {
	return figureA(n);
}
export function figureD(n: number) {
	return figureB(n) + 1;
}
