// A number read before its declaration ran: its binding keeps a ready flag beside it.

function next(): number {
	return count + 1;
}

console.log(next());
let count = 1;
