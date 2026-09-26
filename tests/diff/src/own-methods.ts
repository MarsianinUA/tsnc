// An object converts to a string by the methods Node would look for on it. An optional toString
// that was never set is no property, and a valueOf that is no function is passed over, so both
// objects here print as the object they are.

interface Tagged {
	a: number;
	toString?: () => string;
}

const plain: Tagged = { a: 1 };
console.log("" + plain);
console.log(String(plain));
console.log(`${plain}`);
console.log([plain, plain].join("|"));

const valued = { valueOf: 1, n: 2 };
console.log("" + valued, `${valued}`, String(valued));
