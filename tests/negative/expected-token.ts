// A token the grammar needs is missing. The message stands where it was needed, or at the end of
// the line before when the next token starts a line of its own, and names what was found. The
// parser then skips to the next statement, and what it kept shows: `p > = q` keeps an assignment
// to `p > q`, and `p > > q` orders the answer of `p >` against `q`. A member of an object type
// needs its type, an interface its body, and a function its body; a class or an enum it skips
// whole, up to the end of its body.
// expect: T1007 23:10
// expect: T1007 24:10
// expect: T1007 25:5
// expect: T1007 26:12 "expected `;`, found `foo`"
// expect: T1007 29:5
// expect: T3001 29:7
// expect: T3005 30:1
// expect: T1007 30:5
// expect: T1007 32:3
// expect: T1007 33:5
// expect: T1007 35:12
// expect: T1007 37:14
// expect: T2009 38:1
// expect: T2009 40:1
// expect: T2013 43:1
// expect: T1007 47:1 "expected `)`, found end of file"
let a1 = ;
let a2 = )
let class = 1
let a3 = 1 foo
let p = 1;
let q = 2;
p > = q;
p > > q;
type T = {
	a;
	m()
};
interface I
let y1 = 1;
function g() return 1
class A extends B<{ x: number }> { m() {} }
let y2 = 2;
class C<T {
}
let y3 = 2;
enum E
let y4 = 2;
function call(a: number, b: number): void {}
call(1, 2
