// `break` needs a loop or a `switch` around it, and `continue` needs a loop, which a `switch`
// alone is not. A function starts afresh: the loop around an arrow is not a loop of its body. A
// jump with nowhere to go does not end the path, so the body of `halt` still runs off its end.
// expect: T1013 10:1
// expect: T1014 11:1
// expect: T1013 13:23
// expect: T1014 17:3
// expect: T3024 25:27
// expect: T1013 26:2
break;
continue;
while (true) {
	const stop = () => { break; };
}
switch (1) {
	case 1:
		continue;
}
while (true) {
	switch (1) {
		case 1:
			continue;
	}
}
function halt(x: number): number {
	break;
}
