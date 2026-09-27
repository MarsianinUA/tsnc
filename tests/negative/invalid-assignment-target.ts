// An assignment, `++` and `--` write to a variable, a field or an element. A call, an operator and
// a literal are none of those. The value is still checked against the target, which is how `1 = 2`
// also gets a type error.
// expect: T1011 16:1
// expect: T1011 17:1
// expect: T1011 18:1
// expect: T3001 18:5
// expect: T1011 19:1
// expect: T1011 20:3
function f(): number {
	return 1;
}
let a = 1;
let b = 2;
let c = 3;
f() = 1;
a + b = c;
1 = 2;
f()++;
++1;
