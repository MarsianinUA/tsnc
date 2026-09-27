// Decorators are never supported: requirements 2.2, "Never". A decorated class is reported for the
// class as well; a decorated function is kept without its decorator.
// expect: T2004 8:1
// expect: T2004 11:1
// expect: T2009 12:1
// expect: T2004 13:1
// expect: T2004 15:2
@logged
function tagged() {
}
@sealed
class Sealed {}
@log() function traced() {}
function g(): void {
	@logged
	function inner() {}
}
