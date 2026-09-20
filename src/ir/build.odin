package ir

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import "../abi"
import "../source"

/*
Building a Program_IR. lower opens a Program_Builder, interns what the whole program shares, and
builds one function at a time through a Func_Builder; finish freezes both into the layer codegen
reads.

Declare, then define. declare_func reserves a row before a body exists, so a call may name a
function built later: two functions that call each other, or a module init calling a function
declared below it.

Memory: every row, list and key comes from the allocator make_builder was given, which is meant to
be an arena. What the builder needs only while building, the two intern maps and the key buffer,
goes back in finish; nothing else is ever freed. Names, paths and the slices inside a variant may be
scratch of the caller: emit copies what it keeps, and the package doc says which strings it borrows.
*/

// Program_Builder holds the program under construction. Read its fields freely; write them through
// the procedures below.
Program_Builder :: struct {
	allocator:   runtime.Allocator,
	funcs:       [dynamic]Func,
	layouts:     [dynamic]abi.Type_Table,
	globals:     [dynamic]Global,
	// Program_IR calls this one strings; here that name belongs to the import.
	string_pool: [dynamic][]u16,
	fail_sites:  [dynamic]abi.Fail_Site,
	// The interned rows by key. They are only ever read by key: Odin's map iteration order changes
	// between runs, and nothing whose order reaches the output may come out of a map.
	layout_ids:  map[string]Layout_ID,
	string_ids:  map[string]String_ID,
	site_ids:    map[abi.Fail_Site]Fail_Site_ID,
	// The buffer a layout key is built in. Nothing interns while a key is being built, so one
	// buffer serves every call and a probe lives only until the next one.
	key:         strings.Builder,
}

// make_builder opens a builder whose rows all come from allocator. Layout row 0 is reserved for
// NO_LAYOUT, so it is there from the start and no program ever names it.
make_builder :: proc(allocator := context.allocator) -> Program_Builder {
	return {
		allocator = allocator,
		funcs = make([dynamic]Func, allocator),
		layouts = make([dynamic]abi.Type_Table, 1, 16, allocator),
		globals = make([dynamic]Global, allocator),
		string_pool = make([dynamic][]u16, allocator),
		fail_sites = make([dynamic]abi.Fail_Site, allocator),
		layout_ids = make(map[string]Layout_ID, allocator),
		string_ids = make(map[string]String_ID, allocator),
		site_ids = make(map[abi.Fail_Site]Fail_Site_ID, allocator),
		key = strings.builder_make(allocator),
	}
}

// object_layout is the layout of an object cell whose fields are these, in the canonical order
// lower chose. Two calls with the same shape answer the same Layout_ID: the layout is a function of
// the structure, which is what lets Point and Vec2 share one.
object_layout :: proc(p: ^Program_Builder, fields: []Slot) -> Layout_ID {
	return intern_layout(p, .Object, fields, .Number)
}

// environment_layout is the layout of the cell a closure captures its variables in. The slots have
// no names: nothing looks a captured variable up by name.
environment_layout :: proc(p: ^Program_Builder, slots: []abi.Slot_Kind) -> Layout_ID {
	fields := make([]Slot, len(slots), context.temp_allocator)
	for kind, i in slots {
		fields[i] = {
			kind = kind,
		}
	}
	return intern_layout(p, .Environment, fields, .Number)
}

// array_layout is the layout of an array cell holding unboxed elements of this kind. The elements
// live in an allocation of their own, so the cell has the fixed size of abi.Array_Cell.
array_layout :: proc(p: ^Program_Builder, element: abi.Slot_Kind) -> Layout_ID {
	return intern_layout(p, .Array, nil, element)
}

// intern_string adds a string constant to the pool and answers where it landed. text is the cooked
// value of a literal, which parse keeps in UTF-8, and the pool holds UTF-16 units, which is what a
// cell holds and what codegen emits.
intern_string :: proc(p: ^Program_Builder, text: string) -> String_ID {
	if id, found := p.string_ids[text]; found {
		return id
	}
	id := String_ID(len(p.string_pool))
	append(&p.string_pool, encode_units(text, p.allocator))
	p.string_ids[strings.clone(text, p.allocator)] = id
	return id
}

// add_global adds a module-level binding. name is borrowed and must outlive the program. A global
// is zero filled before any module runs, so a Tagged one starts as undefined.
add_global :: proc(p: ^Program_Builder, name: string, type: Type) -> Global_ID {
	id := Global_ID(len(p.globals))
	append(&p.globals, Global{name = name, type = type})
	return id
}

// fail_site records where generated code may fail and answers where it landed. The path inside the
// site is borrowed and must outlive the program. lower resolves the line and the column, because
// only source can turn an offset into them; see the package doc.
fail_site :: proc(p: ^Program_Builder, site: abi.Fail_Site) -> Fail_Site_ID {
	if id, found := p.site_ids[site]; found {
		return id
	}
	id := Fail_Site_ID(len(p.fail_sites))
	append(&p.fail_sites, site)
	p.site_ids[site] = id
	return id
}

// declare_func reserves the row of a function so that a call can name it before its body exists.
// name is the symbol codegen emits and is borrowed. env names the layout of the environment a
// closure body receives ahead of its parameters; NO_LAYOUT means the function captures nothing.
declare_func :: proc(
	p: ^Program_Builder,
	name: string,
	params: []Type,
	result: Type,
	span: source.Span,
	env := NO_LAYOUT,
) -> Func_ID {
	id := Func_ID(len(p.funcs))
	append(
		&p.funcs,
		Func {
			name = name,
			span = span,
			params = slice.clone(params, p.allocator),
			result = result,
			env = env,
		},
	)
	return id
}

// Func_Builder holds one function under construction. It is built into the row declare_func
// reserved, and end_func writes it there.
Func_Builder :: struct {
	program: ^Program_Builder,
	id:      Func_ID,
	values:  [dynamic]Instruction,
	blocks:  [dynamic][dynamic]Value_ID,
	phis:    [dynamic]Phi_Edges,
	current: Block_ID, // the block emit appends to, or NO_BLOCK once a terminator closed it
}

// begin_func opens the body of a declared function. It opens ENTRY and emits one Param per
// parameter, so parameter i is Value_ID(i). A closure body takes its environment ahead of them all,
// in the calling convention rather than as a Param.
begin_func :: proc(p: ^Program_Builder, id: Func_ID) -> Func_Builder {
	ensure(int(id) < len(p.funcs), "begin_func on a function that was never declared")
	f := Func_Builder {
		program = p,
		id      = id,
		values  = make([dynamic]Instruction, p.allocator),
		blocks  = make([dynamic][dynamic]Value_ID, p.allocator),
		phis    = make([dynamic]Phi_Edges, p.allocator),
		current = NO_BLOCK,
	}
	use_block(&f, add_block(&f))
	declared := p.funcs[id]
	for type, i in declared.params {
		emit(&f, type, Param{index = i32(i)}, declared.span)
	}
	return f
}

// add_block opens an empty block and answers its id. Nothing goes into it until use_block.
add_block :: proc(f: ^Func_Builder) -> Block_ID {
	id := Block_ID(len(f.blocks))
	append(&f.blocks, make([dynamic]Value_ID, f.program.allocator))
	return id
}

// use_block makes block the one emit appends to.
use_block :: proc(f: ^Func_Builder, block: Block_ID) {
	assert(int(block) < len(f.blocks), "use_block on a block of another function")
	f.current = block
}

// emit adds an instruction to the open block and answers the value it defines, which is of type
// VOID when it defines none.
//
// The type is the caller's to state. ir cannot work it out: a reference slot of a layout names no
// layout of its own, a runtime export declares only a pointer or nothing, and a function value
// carries no signature at all. The verifier checks that the type suits the variant.
//
// A terminator closes its block, so whatever follows it goes into a block of its own. Emitting into
// a closed block is a mistake of the caller, not an instruction quietly dropped.
emit :: proc(f: ^Func_Builder, type: Type, variant: Variant, span: source.Span) -> Value_ID {
	assert(f.current != NO_BLOCK, "emit after a terminator closed the block")
	_, is_phi := variant.(Phi)
	assert(!is_phi, "a phi is built with phi and phi_incoming: its edges arrive later")

	id := add_value(f, {span = span, type = type, variant = own(f.program, variant)})
	if terminates(variant) {
		f.current = NO_BLOCK
	}
	return id
}

// phi adds the value a block receives from whichever predecessor control came through. Its edges
// arrive later, through phi_incoming, because the back edge of a loop header is known only once the
// body is built; LLVM patches a phi the same way.
phi :: proc(f: ^Func_Builder, type: Type, span: source.Span) -> Value_ID {
	assert(f.current != NO_BLOCK, "phi after a terminator closed the block")
	assert(only_phis(f, f.current), "a phi comes before every other instruction of its block")

	id := add_value(f, {span = span, type = type, variant = Phi{}})
	append(&f.phis, Phi_Edges{value = id, incoming = make([dynamic]Incoming, f.program.allocator)})
	return id
}

// phi_incoming adds the edge "control came through block, so the phi is value". There is one edge
// per predecessor edge, so a branch that names one block on both sides gives it two.
phi_incoming :: proc(f: ^Func_Builder, phi: Value_ID, block: Block_ID, value: Value_ID) {
	for &edges in f.phis {
		if edges.value == phi {
			append(&edges.incoming, Incoming{block = block, value = value})
			return
		}
	}
	assert(false, "phi_incoming on a value that is not a phi of this function")
}

// end_func freezes the function into the row it was declared in.
end_func :: proc(f: ^Func_Builder) {
	for edges in f.phis {
		f.values[edges.value].variant = Phi {
			incoming = edges.incoming[:],
		}
	}
	blocks := make([]Block, len(f.blocks), f.program.allocator)
	for i in 0 ..< len(f.blocks) {
		blocks[i] = {
			instructions = f.blocks[i][:],
		}
	}

	declared := &f.program.funcs[f.id]
	declared.blocks = blocks
	declared.values = f.values[:]
}

// finish freezes the program. main is the function that takes the abi.MAIN_SYMBOL name and calls
// the module init functions of init_order in turn. v1 puts every function in one unit.
//
// The builder is spent afterwards: what only building needed goes back here.
finish :: proc(p: ^Program_Builder, main: Func_ID, init_order: []Func_ID) -> Program_IR {
	ensure(int(main) < len(p.funcs), "main names a function that was never declared")
	delete(p.layout_ids)
	delete(p.string_ids)
	delete(p.site_ids)
	strings.builder_destroy(&p.key)

	all := make([]Func_ID, len(p.funcs), p.allocator)
	for i in 0 ..< len(all) {
		all[i] = Func_ID(i)
	}
	units := make([]Unit, 1, p.allocator)
	units[0] = {
		funcs = all,
	}

	return {
		funcs = p.funcs[:],
		layouts = p.layouts[:],
		globals = p.globals[:],
		strings = p.string_pool[:],
		fail_sites = p.fail_sites[:],
		init_order = slice.clone(init_order, p.allocator),
		main = main,
		units = units,
	}
}

// Phi_Edges collects the incoming edges of one phi while they are still arriving. end_func freezes
// them into the instruction, because Phi.incoming is a slice of a layer that no longer changes.
@(private)
Phi_Edges :: struct {
	value:    Value_ID,
	incoming: [dynamic]Incoming,
}

@(private)
add_value :: proc(f: ^Func_Builder, instruction: Instruction) -> Value_ID {
	id := Value_ID(len(f.values))
	append(&f.values, instruction)
	append(&f.blocks[f.current], id)
	return id
}

@(private)
only_phis :: proc(f: ^Func_Builder, block: Block_ID) -> bool {
	for id in f.blocks[block] {
		if _, is_phi := f.values[id].variant.(Phi); !is_phi {
			return false
		}
	}
	return true
}

// own copies the lists a variant points at into the program: a caller may have built them in its
// own scratch. Only the variants that carry a list have anything to copy.
@(private)
own :: proc(p: ^Program_Builder, variant: Variant) -> Variant {
	#partial switch v in variant {
	case Call:
		return Call{func = v.func, args = slice.clone(v.args, p.allocator)}
	case Call_Closure:
		return Call_Closure{callee = v.callee, args = slice.clone(v.args, p.allocator)}
	case Call_Runtime:
		return Call_Runtime{export = v.export, args = slice.clone(v.args, p.allocator)}
	case Intrinsic:
		return Intrinsic{op = v.op, args = slice.clone(v.args, p.allocator)}
	}
	return variant
}

// intern_layout is the one way a layout enters the program. The slots may be scratch: a shape that
// is there already is found by its key alone, and only a new one copies its fields.
@(private)
intern_layout :: proc(
	p: ^Program_Builder,
	kind: abi.Cell_Kind,
	fields: []Slot,
	element: abi.Slot_Kind,
) -> Layout_ID {
	strings.builder_reset(&p.key)
	write_layout_key(&p.key, kind, fields, element)
	probe := strings.to_string(p.key)
	if id, found := p.layout_ids[probe]; found {
		return id
	}

	table := abi.Type_Table {
		kind    = kind,
		size    = fixed_size(kind),
		element = element,
	}
	if len(fields) > 0 {
		owned := make([]abi.Field, len(fields), p.allocator)
		offset := table.size
		for slot, i in fields {
			owned[i] = {
				name   = slot.name,
				offset = offset,
				kind   = slot.kind,
			}
			offset += abi.SLOT_SIZE[slot.kind]
		}
		table.fields = owned
		table.size = offset
	}

	id := Layout_ID(len(p.layouts))
	append(&p.layouts, table)
	p.layout_ids[strings.clone(probe, p.allocator)] = id
	return id
}

// write_layout_key writes the key a layout is interned under: the kind, the element kind and every
// slot in order. A name is quoted, so no name can spell the separators. The key is internal, never
// printed and never ordered.
@(private)
write_layout_key :: proc(
	b: ^strings.Builder,
	kind: abi.Cell_Kind,
	fields: []Slot,
	element: abi.Slot_Kind,
) {
	strings.write_int(b, int(kind))
	strings.write_byte(b, '|')
	strings.write_int(b, int(element))
	for slot in fields {
		strings.write_byte(b, ',')
		strings.write_quoted_string(b, slot.name)
		strings.write_byte(b, ':')
		strings.write_int(b, int(slot.kind))
	}
}

// fixed_size is the size of the part of a cell that comes before its slots.
@(private)
fixed_size :: proc(kind: abi.Cell_Kind) -> int {
	switch kind {
	case .Object, .Environment:
		return size_of(abi.Cell_Header)
	case .Array:
		return size_of(abi.Array_Cell)
	case .String:
		return size_of(abi.String_Cell)
	case .Closure:
		return size_of(abi.Closure_Cell)
	}
	return size_of(abi.Cell_Header)
}

// encode_units turns the cooked text of a string literal into UTF-16 units.
//
// It is not utf16.encode_string, which decodes runes: parse keeps a lone surrogate escape such as
// \uD800 in its three-byte WTF-8 form, precisely so that lower gets back every unit the program
// wrote (ast.String_Literal), and decoding that as a rune yields U+FFFD and loses the unit.
@(private)
encode_units :: proc(text: string, allocator: runtime.Allocator) -> []u16 {
	// UTF-8 never takes fewer bytes than UTF-16 takes units.
	units := make([dynamic]u16, 0, len(text), allocator)
	for i := 0; i < len(text); {
		if unit, size := surrogate_at(text, i); size > 0 {
			append(&units, unit)
			i += size
			continue
		}
		r, size := utf8.decode_rune_in_string(text[i:])
		i += max(size, 1)
		if r <= 0xFFFF {
			append(&units, u16(r))
			continue
		}
		rest := u32(r) - 0x10000
		append(&units, u16(0xD800 + (rest >> 10)), u16(0xDC00 + (rest & 0x3FF)))
	}
	return units[:]
}

// surrogate_at answers the UTF-16 unit of a surrogate encoded in WTF-8 at i, and a size of zero
// when the bytes there are anything else.
@(private)
surrogate_at :: proc(text: string, i: int) -> (unit: u16, size: int) {
	if i + 3 > len(text) || text[i] != 0xED {
		return 0, 0
	}
	lead, trail := text[i + 1], text[i + 2]
	if lead < 0xA0 || lead > 0xBF || trail < 0x80 || trail > 0xBF {
		return 0, 0
	}
	return 0xD000 | (u16(lead & 0x3F) << 6) | u16(trail & 0x3F), 3
}
