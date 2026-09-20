// Prototypes are never supported: requirements 2.2, "Never". An object is the fields its type
// declares and nothing behind them, so `__proto__` names no slot at all.
// expect: T2024 5:21
const point = { x: 1 };
const chain = point.__proto__;
