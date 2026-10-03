#+private
package opt

import "core:math"
import "core:slice"

import "../abi"
import "../ir"

/*
The values each number may take, for bounds and narrow; nothing here rewrites the IR.

Bounds are computed with the same correctly rounded f64 operations as the program, on the ends of
the operands' intervals. Rounding is monotone, so the program's own result lies between them. A
range that may reach ±2^53 is Top: past it f64 rounds integers, and no integer type computes what
the program does there.

A loop is solved by iteration: ascending, the phis of a loop header widen to the next threshold
after two rounds; descending, two more rounds take back what widening gave away. Across functions,
one fixpoint joins what reaches a number global, a parameter of a function only ever called
directly, and the result of a direct call.
*/

@(private = "file")
SAFE :: 9_007_199_254_740_991 // 2^53 - 1, Number.MAX_SAFE_INTEGER

Range_Kind :: enum u8 {
	Bottom, // no value: the code never runs, or the analysis has not reached it yet
	Integral, // whole numbers in [lo, hi]
	Real, // numbers in [lo, hi], neither NaN nor an infinity
	Top, // any number, NaN and the infinities too
}

Range :: struct {
	kind:          Range_Kind,
	negative_zero: bool, // -0 may be among the values; only ever with 0 in [lo, hi]
	lo, hi:        f64, // within ±SAFE
}

@(private = "file")
TOP :: Range {
	kind = .Top,
}
INT32 :: Range {
	kind = .Integral,
	lo   = -(1 << 31),
	hi   = (1 << 31) - 1,
}

Ranges :: struct {
	funcs:        []Func_Ranges, // by Func_ID
	string_limit: f64, // the most units a string of the program holds
}

Func_Ranges :: struct {
	values: []Range, // by Value_ID; Bottom for a value that is no number
	// facts[v] are the comparisons of v with another number that a branch into a block made, with
	// the deepest block of the dominator tree first, so a block's nearest dominator comes first
	// among those that dominate it.
	facts:  [][]Fact,
	flow:   ir.Flow,
}

// Fact holds in `block`, which only a branch on the comparison enters.
Fact :: struct {
	compare: ir.Compare,
	holds:   bool, // the block is the true side
	block:   ir.Block_ID,
}

find_ranges :: proc(p: ir.Program_IR, shapes: []Shape) -> Ranges {
	a := Analysis {
		program = p,
		shapes  = shapes,
		globals = make([]Summary, len(p.globals), context.temp_allocator),
		params  = make([][]Summary, len(p.funcs), context.temp_allocator),
		returns = make([]Summary, len(p.funcs), context.temp_allocator),
		dirty   = make([]bool, len(p.funcs), context.temp_allocator),
		readers = make([][dynamic]ir.Func_ID, len(p.globals), context.temp_allocator),
		callers = make([][dynamic]ir.Func_ID, len(p.funcs), context.temp_allocator),
		grown   = make([dynamic]int, context.temp_allocator),
	}
	a.ranges = {
		funcs        = make([]Func_Ranges, len(p.funcs), context.temp_allocator),
		string_limit = abi.MAX_STRING_LENGTH,
	}
	for units in p.strings {
		a.ranges.string_limit = max(a.ranges.string_limit, f64(len(units)))
	}
	// A module global is 0 before its first store.
	for global, id in p.globals {
		if global.type == ir.F64 {
			a.globals[id].range = {
				kind = .Integral,
			}
		}
	}
	link_summaries(&a)
	for id in 0 ..< len(p.funcs) {
		a.ranges.funcs[id] = prepare(p.funcs[id], shapes[id].flow)
		a.dirty[id] = true
	}

	for {
		visited := false
		for id in 0 ..< len(p.funcs) {
			if !a.dirty[id] {
				continue
			}
			a.dirty[id] = false
			visited = true
			analyze(&a, ir.Func_ID(id))
			contribute(&a, ir.Func_ID(id))
		}
		if !visited {
			break
		}
	}
	return a.ranges
}

// refined narrows a range by the facts that hold where `block` runs. A fact's edge ran after the
// latest definition of the value, so its condition is about this value.
refined :: proc(fr: Func_Ranges, value: ir.Value_ID, block: ir.Block_ID) -> Range {
	r := fr.values[value]
	if r.kind == .Bottom || len(fr.facts[value]) == 0 {
		return r
	}
	iv := interval_of(r)
	for fact in fr.facts[value] {
		if ir.dominates(fr.flow, fact.block, block) {
			iv = apply_fact(fr, fact, value, iv)
		}
	}
	return range_of(iv)
}

// fact_of answers the number comparison the single predecessor of `block` branched on; holds says
// the block is its true side.
@(private = "file")
fact_of :: proc(
	flow: ir.Flow,
	func: ir.Func,
	block: ir.Block_ID,
) -> (
	compare: ir.Compare,
	holds: bool,
	ok: bool,
) {
	if len(flow.preds[block]) != 1 {
		return
	}
	pred := flow.preds[block][0]
	instructions := func.blocks[pred].instructions
	branch, is_branch := func.values[instructions[len(instructions) - 1]].variant.(ir.Branch)
	if !is_branch || branch.then_block == branch.else_block {
		return
	}
	is_compare: bool
	compare, is_compare = func.values[branch.condition].variant.(ir.Compare)
	if !is_compare || func.values[compare.left].type != ir.F64 {
		return
	}
	return compare, branch.then_block == block, true
}

@(private = "file")
Analysis :: struct {
	program: ir.Program_IR,
	shapes:  []Shape, // by Func_ID
	ranges:  Ranges,
	globals: []Summary, // by Global_ID
	params:  [][]Summary, // by Func_ID, then parameter; nil for a function called from elsewhere
	returns: []Summary, // by Func_ID
	dirty:   []bool, // by Func_ID: a summary it reads grew since it was last analyzed
	readers: [][dynamic]ir.Func_ID, // by Global_ID: the functions that load it
	callers: [][dynamic]ir.Func_ID, // by Func_ID: the functions that call it directly
	grown:   [dynamic]int, // by Value_ID of the function being analyzed
}

@(private = "file")
Summary :: struct {
	range: Range,
	grown: int,
}

// link_summaries knows a function's callers only when no closure of it exists: the runtime calls
// comparators, and a closure may be called from anywhere. main and the module inits count as
// entry points.
@(private = "file")
link_summaries :: proc(a: ^Analysis) {
	p := a.program
	for &list in a.callers {
		list = make([dynamic]ir.Func_ID, context.temp_allocator)
	}
	for &list in a.readers {
		list = make([dynamic]ir.Func_ID, context.temp_allocator)
	}
	escapes := make([]bool, len(p.funcs), context.temp_allocator)
	escapes[p.main] = true
	for id in p.init_order {
		escapes[id] = true
	}
	for func, id in p.funcs {
		for instruction in func.values {
			#partial switch v in instruction.variant {
			case ir.Func_Ref:
				escapes[v.func] = true
			case ir.Make_Closure:
				escapes[v.func] = true
			case ir.Call:
				append_once(&a.callers[v.func], ir.Func_ID(id))
			case ir.Global_Load:
				append_once(&a.readers[v.global], ir.Func_ID(id))
			}
		}
	}
	for func, id in p.funcs {
		if !escapes[id] {
			a.params[id] = make([]Summary, len(func.params), context.temp_allocator)
		}
	}
}

@(private = "file")
append_once :: proc(list: ^[dynamic]ir.Func_ID, id: ir.Func_ID) {
	if len(list) == 0 || list[len(list) - 1] != id {
		append(list, id)
	}
}

// prepare builds what every analysis of the function reads and never changes.
@(private = "file")
prepare :: proc(func: ir.Func, flow: ir.Flow) -> Func_Ranges {
	About :: struct {
		value: ir.Value_ID,
		pre:   i32,
		fact:  Fact,
	}
	fr := Func_Ranges {
		values = make([]Range, len(func.values), context.temp_allocator),
		facts  = make([][]Fact, len(func.values), context.temp_allocator),
		flow   = flow,
	}
	found := make([dynamic]About, context.temp_allocator)
	for block in flow.order {
		// The call enters ENTRY too, so no branch speaks for it.
		if block == ir.ENTRY {
			continue
		}
		compare, holds, ok := fact_of(flow, func, block)
		if !ok || compare.left == compare.right {
			continue
		}
		fact := Fact {
			compare = compare,
			holds   = holds,
			block   = block,
		}
		pre := flow.pre[block]
		append(&found, About{compare.left, pre, fact}, About{compare.right, pre, fact})
	}
	slice.sort_by(found[:], proc(a, b: About) -> bool {
		return a.value < b.value || a.value == b.value && a.pre > b.pre
	})
	facts := make([]Fact, len(found), context.temp_allocator)
	for about, i in found {
		facts[i] = about.fact
	}
	for start := 0; start < len(found); {
		end := start + 1
		for end < len(found) && found[end].value == found[start].value {
			end += 1
		}
		fr.facts[found[start].value] = facts[start:end]
		start = end
	}
	return fr
}

@(private = "file")
analyze :: proc(a: ^Analysis, id: ir.Func_ID) {
	func := a.program.funcs[id]
	shape := a.shapes[id]
	fr := &a.ranges.funcs[id]
	for &r in fr.values {
		r = {}
	}
	resize(&a.grown, len(func.values))
	for &count in a.grown {
		count = 0
	}

	// Ascending.
	for changed := true; changed; {
		changed = false
		for block in shape.flow.order {
			for value in func.blocks[block].instructions {
				if func.values[value].type != ir.F64 {
					continue
				}
				r := compute(a, id, value, block)
				_, is_phi := func.values[value].variant.(ir.Phi)
				if is_phi && shape.header[block] {
					changed |= grow(&fr.values[value], &a.grown[value], r)
				} else {
					old := fr.values[value]
					fr.values[value] = join(old, r)
					changed |= fr.values[value] != old
				}
			}
		}
	}

	// Descending: each round starts from ranges that hold, so its result holds too.
	for _ in 0 ..< 2 {
		for block in shape.flow.order {
			for value in func.blocks[block].instructions {
				if func.values[value].type == ir.F64 {
					fr.values[value] = compute(a, id, value, block)
				}
			}
		}
	}
}

@(private = "file")
contribute :: proc(a: ^Analysis, id: ir.Func_ID) {
	func := a.program.funcs[id]
	fr := a.ranges.funcs[id]
	for block in a.shapes[id].flow.order {
		for value in func.blocks[block].instructions {
			#partial switch v in func.values[value].variant {
			case ir.Global_Store:
				if a.program.globals[v.global].type != ir.F64 {
					continue
				}
				global := &a.globals[v.global]
				if grow(&global.range, &global.grown, refined(fr, v.value, block)) {
					for reader in a.readers[v.global] {
						a.dirty[reader] = true
					}
				}
			case ir.Call:
				params := a.params[v.func]
				if params == nil {
					continue
				}
				for arg, i in v.args {
					if func.values[arg].type != ir.F64 {
						continue
					}
					if grow(&params[i].range, &params[i].grown, refined(fr, arg, block)) {
						a.dirty[v.func] = true
					}
				}
			case ir.Return:
				if func.result != ir.F64 {
					continue
				}
				result := &a.returns[id]
				if grow(&result.range, &result.grown, refined(fr, v.value, block)) {
					for caller in a.callers[id] {
						a.dirty[caller] = true
					}
				}
			}
		}
	}
}

@(private = "file")
grow :: proc(range: ^Range, grown: ^int, r: Range) -> bool {
	new := join(range^, r)
	if new == range^ {
		return false
	}
	grown^ += 1
	if grown^ > 2 {
		new = widen(range^, new)
	}
	range^ = new
	return true
}

@(private = "file")
compute :: proc(a: ^Analysis, id: ir.Func_ID, value: ir.Value_ID, block: ir.Block_ID) -> Range {
	func := a.program.funcs[id]
	fr := a.ranges.funcs[id]
	#partial switch v in func.values[value].variant {
	case ir.Const_Number:
		return constant(v.value)
	case ir.Param:
		if params := a.params[id]; params != nil {
			return params[v.index].range
		}
	case ir.Binary:
		return binary(v.op, refined(fr, v.left, block), refined(fr, v.right, block))
	case ir.Unary:
		operand := refined(fr, v.operand, block)
		if operand.kind == .Bottom {
			return {}
		}
		if v.op == .Bit_Not {
			return INT32
		}
		return negate(operand)
	case ir.Phi:
		r: Range
		for edge in v.incoming {
			r = join(r, refined(fr, edge.value, edge.block))
		}
		return r
	case ir.Length:
		return {kind = .Integral, hi = length_limit(a, func, v.value)}
	case ir.Unit_Load:
		return {kind = .Integral, hi = 65535}
	case ir.Bounds_Check:
		return checked(refined(fr, v.index, block), length_limit(a, func, v.array))
	case ir.Intrinsic:
		return intrinsic(v.op, refined(fr, v.args[0], block))
	case ir.Global_Load:
		return a.globals[v.global].range
	case ir.Call:
		return a.returns[v.func].range
	}
	return TOP
}

@(private = "file")
length_limit :: proc(a: ^Analysis, func: ir.Func, cell: ir.Value_ID) -> f64 {
	return a.ranges.string_limit if func.values[cell].type == ir.STR else abi.MAX_ARRAY_LENGTH
}

@(private = "file")
constant :: proc(value: f64) -> Range {
	if math.is_nan(value) || abs(value) > SAFE {
		return TOP
	}
	kind := Range_Kind.Integral if value == math.trunc(value) else .Real
	return {
		kind = kind,
		negative_zero = value == 0 && math.sign_bit(value),
		lo = value,
		hi = value,
	}
}

@(private = "file")
binary :: proc(op: ir.Binary_Op, a, b: Range) -> Range {
	if a.kind == .Bottom || b.kind == .Bottom {
		return {}
	}
	whole := a.kind == .Integral && b.kind == .Integral
	switch op {
	case .Add:
		if a.kind == .Top || b.kind == .Top {
			return TOP
		}
		return make_range(whole, a.lo + b.lo, a.hi + b.hi, a.negative_zero && b.negative_zero)
	case .Subtract:
		if a.kind == .Top || b.kind == .Top {
			return TOP
		}
		// -0 - +0 is the one difference that is -0.
		return make_range(whole, a.lo - b.hi, a.hi - b.lo, a.negative_zero && holds_zero(b))
	case .Multiply:
		if a.kind == .Top || b.kind == .Top {
			return TOP
		}
		p := [4]f64{a.lo * b.lo, a.lo * b.hi, a.hi * b.lo, a.hi * b.hi}
		lo, hi := min(p[0], p[1], p[2], p[3]), max(p[0], p[1], p[2], p[3])
		// A zero times a number of the other sign is -0. Two fractions may also round to a zero
		// of either sign, so a product with a Real in it may be -0 wherever 0 is in its range.
		negative_zero := !whole || zero_times_other_sign(a, b) || zero_times_other_sign(b, a)
		return make_range(whole, lo, hi, negative_zero)
	case .Divide:
		if !whole || !excludes_zero(b) {
			return TOP
		}
		q := [4]f64{a.lo / b.lo, a.lo / b.hi, a.hi / b.lo, a.hi / b.hi}
		lo, hi := min(q[0], q[1], q[2], q[3]), max(q[0], q[1], q[2], q[3])
		// Whole numbers within ±2^53 never divide to a fraction that rounds to 0.
		negative_zero := holds_zero(a) && b.lo < 0 || a.negative_zero && b.hi > 0
		return make_range(false, lo, hi, negative_zero)
	case .Remainder:
		if !whole || !excludes_zero(b) {
			return TOP
		}
		// |a % b| < |b|, and the sign is the dividend's.
		limit := max(abs(b.lo), abs(b.hi)) - 1
		lo := max(min(0, a.lo), -limit)
		hi := min(max(0, a.hi), limit)
		return make_range(true, lo, hi, a.lo < 0 || a.negative_zero)
	case .Power:
		return TOP
	case .Shift_Left, .Bit_Or, .Bit_Xor:
		return INT32
	case .Shift_Right:
		// A 32 bit integer shifted right stays between itself and 0.
		if a.kind == .Integral && a.lo >= INT32.lo && a.hi <= INT32.hi {
			return {kind = .Integral, lo = min(a.lo, 0), hi = max(a.hi, 0)}
		}
		return INT32
	case .Shift_Right_Unsigned:
		shift := 0
		if b.kind == .Integral && b.lo == b.hi {
			shift = int(i64(b.lo) & 31)
		}
		return {kind = .Integral, hi = f64(u64(1) << uint(32 - shift) - 1)}
	case .Bit_And:
		// A non-negative 32 bit side keeps the result between 0 and itself.
		hi := INT32.hi
		for side in ([2]Range{a, b}) {
			if side.kind == .Integral && side.lo >= 0 && side.hi <= INT32.hi {
				hi = min(hi, side.hi)
			}
		}
		if hi < INT32.hi {
			return {kind = .Integral, hi = hi}
		}
		return INT32
	}
	return TOP
}

@(private = "file")
negate :: proc(r: Range) -> Range {
	if r.kind == .Top {
		return TOP
	}
	return {kind = r.kind, negative_zero = holds_zero(r), lo = -r.hi, hi = -r.lo}
}

// checked is the answer of a bounds check, an integer inside [0, limit).
@(private = "file")
checked :: proc(index: Range, limit: f64) -> Range {
	if index.kind == .Bottom {
		return {}
	}
	iv := interval_of(index)
	lo := max(math.ceil(iv.lo), 0)
	hi := min(math.floor(iv.hi), limit - 1)
	if lo > hi {
		return {}
	}
	return {kind = .Integral, negative_zero = iv.negative_zero && lo == 0, lo = lo, hi = hi}
}

@(private = "file")
intrinsic :: proc(op: ir.Intrinsic_Op, r: Range) -> Range {
	if r.kind == .Bottom {
		return {}
	}
	if r.kind == .Top {
		return TOP
	}
	#partial switch op {
	case .Floor:
		return make_range(true, math.floor(r.lo), math.floor(r.hi), r.negative_zero)
	case .Ceil, .Trunc:
		// A fraction in (-1, 0) goes to -0.
		negative_zero := r.negative_zero || r.lo < 0 && r.hi > -1
		if op == .Ceil {
			return make_range(true, math.ceil(r.lo), math.ceil(r.hi), negative_zero)
		}
		return make_range(true, math.trunc(r.lo), math.trunc(r.hi), negative_zero)
	case .Abs:
		if r.lo >= 0 {
			return {kind = r.kind, lo = r.lo, hi = r.hi}
		}
		if r.hi <= 0 {
			return {kind = r.kind, lo = -r.hi, hi = -r.lo}
		}
		return {kind = r.kind, hi = max(-r.lo, r.hi)}
	}
	return TOP
}

@(private = "file")
make_range :: proc(whole: bool, lo, hi: f64, negative_zero: bool) -> Range {
	if !(lo >= -SAFE && hi <= SAFE) {
		return TOP
	}
	kind := Range_Kind.Integral if whole else .Real
	return {kind = kind, negative_zero = negative_zero && lo <= 0 && 0 <= hi, lo = lo, hi = hi}
}

@(private = "file")
holds_zero :: proc(r: Range) -> bool {
	return r.lo <= 0 && 0 <= r.hi
}

@(private = "file")
excludes_zero :: proc(r: Range) -> bool {
	return r.lo > 0 || r.hi < 0
}

// zero_times_other_sign says whether a zero of `a` may meet a factor of the other sign in `b`: +0
// times a negative number or -0, or -0 times a positive number or +0.
@(private = "file")
zero_times_other_sign :: proc(a, b: Range) -> bool {
	if !holds_zero(a) {
		return false
	}
	negative := b.lo < 0 || b.negative_zero
	positive := b.hi > 0 || holds_zero(b)
	return negative || a.negative_zero && positive
}

@(private = "file")
join :: proc(a, b: Range) -> Range {
	if a.kind == .Bottom {
		return b
	}
	if b.kind == .Bottom {
		return a
	}
	if a.kind == .Top || b.kind == .Top {
		return TOP
	}
	return {
		kind = max(a.kind, b.kind),
		negative_zero = a.negative_zero || b.negative_zero,
		lo = min(a.lo, b.lo),
		hi = max(a.hi, b.hi),
	}
}

// widen jumps an end that grew to the next threshold, so a loop counter gets there in one step
// rather than in one per iteration.
@(private = "file")
widen :: proc(old, new: Range) -> Range {
	if old.kind == .Bottom || new.kind == .Top {
		return new
	}
	r := new
	if new.lo < old.lo {
		r.lo = INT32.lo if new.lo >= INT32.lo else -SAFE
	}
	if new.hi > old.hi {
		r.hi = INT32.hi if new.hi <= INT32.hi else SAFE
	}
	return r
}

// Interval is a range in the middle of being refined: it may be known not to be NaN while its
// ends are still infinite, which no Range spells.
@(private = "file")
Interval :: struct {
	lo, hi:        f64,
	integral:      bool,
	nan:           bool,
	negative_zero: bool,
	empty:         bool,
}

@(private = "file")
interval_of :: proc(r: Range) -> Interval {
	switch r.kind {
	case .Bottom:
		return {empty = true}
	case .Integral, .Real:
		return {
			lo = r.lo,
			hi = r.hi,
			integral = r.kind == .Integral,
			negative_zero = r.negative_zero,
		}
	case .Top:
	}
	return {lo = math.inf_f64(-1), hi = math.inf_f64(1), nan = true, negative_zero = true}
}

@(private = "file")
range_of :: proc(iv: Interval) -> Range {
	if iv.empty {
		return {}
	}
	lo, hi := iv.lo, iv.hi
	if iv.integral {
		lo, hi = math.ceil(lo), math.floor(hi)
	}
	if lo > hi {
		return {}
	}
	if iv.nan {
		return TOP
	}
	return make_range(iv.integral, lo, hi, iv.negative_zero)
}

@(private = "file")
apply_fact :: proc(fr: Func_Ranges, fact: Fact, value: ir.Value_ID, iv: Interval) -> Interval {
	compare := fact.compare
	if compare.left == compare.right || compare.left != value && compare.right != value {
		return iv
	}
	op := compare.op
	other := compare.right
	if compare.right == value {
		op = MIRRORED[op]
		other = compare.left
	}
	o := interval_of(fr.values[other])
	if !fact.holds {
		// The false side of an ordered comparison says something only when neither side is NaN.
		if op != .Equal && op != .Not_Equal && (iv.nan || o.nan) {
			return iv
		}
		op = NEGATED[op]
	}
	return relate(iv, op, o)
}

// relate narrows v by `v op o`, which holds.
@(private = "file")
relate :: proc(v: Interval, op: ir.Compare_Op, o: Interval) -> Interval {
	v := v
	if v.empty || o.empty {
		// A comparison with a value that never exists never ran.
		return {empty = true}
	}
	switch op {
	case .Less:
		v.hi = min(v.hi, math.ceil(o.hi) - 1 if v.integral else o.hi)
	case .Less_Equal:
		v.hi = min(v.hi, math.floor(o.hi) if v.integral else o.hi)
	case .Greater:
		v.lo = max(v.lo, math.floor(o.lo) + 1 if v.integral else o.lo)
	case .Greater_Equal:
		v.lo = max(v.lo, math.ceil(o.lo) if v.integral else o.lo)
	case .Equal:
		v.lo, v.hi = max(v.lo, o.lo), min(v.hi, o.hi)
		v.integral ||= o.integral
	case .Not_Equal:
		if o.nan || o.lo != o.hi {
			return v
		}
		if v.integral && v.lo == o.lo {
			v.lo += 1
		}
		if v.integral && v.hi == o.lo {
			v.hi -= 1
		}
		// -0 === 0, so a value other than 0 is not -0 either.
		if o.lo == 0 {
			v.negative_zero = false
		}
		return v
	}
	// Every other comparison is false for NaN.
	v.nan = false
	return v
}

@(private = "file", rodata)
MIRRORED := [ir.Compare_Op]ir.Compare_Op {
	.Less          = .Greater,
	.Less_Equal    = .Greater_Equal,
	.Greater       = .Less,
	.Greater_Equal = .Less_Equal,
	.Equal         = .Equal,
	.Not_Equal     = .Not_Equal,
}

@(private = "file", rodata)
NEGATED := [ir.Compare_Op]ir.Compare_Op {
	.Less          = .Greater_Equal,
	.Less_Equal    = .Greater,
	.Greater       = .Less_Equal,
	.Greater_Equal = .Less,
	.Equal         = .Not_Equal,
	.Not_Equal     = .Equal,
}
