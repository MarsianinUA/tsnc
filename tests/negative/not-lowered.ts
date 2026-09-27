// Parts of the v1 language that tsnc types but does not compile yet. `tsnc check` passes the
// program, and `tsnc build` names each construct where it stands. A call to a function it
// refused adds nothing: the function is the one mistake.
// expect: T2027 10:10 "rest parameters"
// expect: T2027 16:13 "`Math.clz32`"
// expect: T2027 17:13 "`Math.fround`"
// expect: T2027 18:13 "`Math.hypot`"
// expect: T2027 19:13 "`Math.imul`"
// expect: T2027 22:1 "short-circuit assignment"
function total(first: number, ...rest: number[]): number {
	return first + rest.length;
}
console.log(total(1));
console.log(total(1, 2, 3));

console.log(Math.clz32(1));
console.log(Math.fround(1.5));
console.log(Math.hypot(3, 4));
console.log(Math.imul(2, 3));

let maybe: number | undefined = undefined;
maybe ??= 1;
console.log(maybe);
