// `break` needs a loop or a `switch` around it, and `continue` needs a loop. A function starts
// afresh: the loop around an arrow is not a loop of its body.
// expect: T1013 6:1
// expect: T1014 7:1
// expect: T1013 9:23
break;
continue;
while (true) {
	const stop = () => { break; };
}
