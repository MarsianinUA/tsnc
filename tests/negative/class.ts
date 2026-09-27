// Classes, `this` and `super` are never supported: requirements 2.2, "Never". A class body is
// skipped rather than read, so a `var` inside it is not reported on its own.
// expect: T2009 9:1
// expect: T2009 12:1
// expect: T2009 13:8
// expect: T2009 18:1
// expect: T2009 19:1
// expect: T2009 21:8
class Shape {
	size: number;
}
abstract class Base {}
export class Derived extends Shape {
	m() {
		var x;
	}
}
this.x = 1;
super.f();
let made: number = 1;
made = class {};
