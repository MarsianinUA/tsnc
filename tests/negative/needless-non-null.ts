// `!` checks at run time that a value is neither `null` nor `undefined`. After a type that can be
// neither there is nothing left to check, so the `!` is a mistake about the type. The same holds
// after a test that already ruled both out.
// expect: T3021 7:14 "nothing to check"
// expect: T3021 13:9
const count: number = 1;
const sure = count!;

function keep(s: string | undefined): string {
	if (s === undefined) {
		return "none";
	}
	return s!;
}
