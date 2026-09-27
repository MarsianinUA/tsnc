// Prototypes are never supported: requirements 2.2, "Never". An object is the fields its type
// declares and nothing behind them, so `__proto__` names no slot at all, whether it is read, written
// in a literal or declared in an interface, and `prototype` names none on a function. A value of
// type `any` gets no exception. A mistake inside the refused literal is still found.
// expect: T2024 13:21
// expect: T2024 16:17
// expect: T2024 18:19
// expect: T2024 20:2
// expect: T2024 24:23
// expect: T2024 26:18
// expect: T3003 26:29
const point = { x: 1 };
const chain = point.__proto__;

function f(): void {}
const shape = f.prototype;

const literal = { __proto__: 1 };
interface Slot {
	__proto__: number;
}

const loose: any = 1;
const through = loose.__proto__;

const broken = { __proto__: "a" * 2 };
