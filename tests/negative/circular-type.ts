// A `type` alias is transparent, so one that stands for itself stands for nothing. An `interface`
// may name itself, because its row is reserved before its members are read.
// expect: T3016 4:21
type Node = { next: Node };
