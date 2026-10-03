#+private
package opt

import "base:runtime"
import "core:slice"

import "../ir"

/*
split_cells takes apart a web of cells, Allocs and the phis that join them, whose fields are
written only where each cell is made, before anything reads it, and are only read after that. Each
field becomes an SSA value, a phi of fields where the web has a phi. No reference to such a cell is
compared, boxed, stored or handed on, so nothing can tell the cell from its fields: escape sees no
cell, LLVM gets registers, and a cell carried from one pass of a loop to the next takes no memory
either.
*/

split_cells :: proc(p: ir.Program_IR, func: ^ir.Func, allocator: runtime.Allocator) {
	s := Splitter {
		func    = func,
		places  = ir.locate_values(func^, context.temp_allocator),
		web     = make([]ir.Value_ID, len(func.values), context.temp_allocator),
		spoiled = make([]bool, len(func.values), context.temp_allocator),
		loaded  = make([][]ir.Type, len(func.values), context.temp_allocator),
		parts   = make([][]ir.Value_ID, len(func.values), context.temp_allocator),
		first   = make([]int, len(func.values), context.temp_allocator),
		fields  = make([dynamic]^ir.Value_ID, context.temp_allocator),
	}
	if !find_webs(&s) {
		return
	}
	find_uses(&s, p)
	if !check_writes(&s) {
		return
	}
	take_apart(&s, allocator)
}

@(private = "file")
Splitter :: struct {
	func:    ^ir.Func,
	places:  []ir.Place,
	web:     []ir.Value_ID, // by Value_ID: the parent in a union-find of webs, NO_VALUE outside one
	spoiled: []bool, // by the root of a web: some use keeps its cells
	loaded:  [][]ir.Type, // by the root of a web, then field: the type its loads read, VOID unread
	// By Value_ID of a member: an Alloc's written value of each field, then a phi's phi of each.
	parts:   [][]ir.Value_ID,
	first:   []int, // by Value_ID of an Alloc: the position of its first read in its own block
	fields:  [dynamic]^ir.Value_ID,
}

// find_webs answers whether the function has a web at all.
@(private = "file")
find_webs :: proc(s: ^Splitter) -> bool {
	found := false
	for instruction, id in s.func.values {
		s.web[id] = ir.NO_VALUE
		if s.places[id].block == ir.NO_BLOCK {
			continue
		}
		#partial switch _ in instruction.variant {
		case ir.Alloc:
			s.web[id], found = ir.Value_ID(id), true
		case ir.Phi:
			if instruction.type.kind == .Ref && instruction.type.nullish == .None {
				s.web[id] = ir.Value_ID(id)
			}
		}
	}
	for instruction, id in s.func.values {
		phi, is_phi := instruction.variant.(ir.Phi)
		if !is_phi || s.web[id] == ir.NO_VALUE {
			continue
		}
		for edge in phi.incoming {
			if s.web[edge.value] == ir.NO_VALUE {
				s.spoiled[root(s, ir.Value_ID(id))] = true
				continue
			}
			a, b := root(s, ir.Value_ID(id)), root(s, edge.value)
			if a != b {
				s.web[b] = a
				s.spoiled[a] ||= s.spoiled[b]
			}
		}
	}
	return found
}

@(private = "file")
root :: proc(s: ^Splitter, value: ir.Value_ID) -> ir.Value_ID {
	value := value
	for s.web[value] != value {
		s.web[value] = s.web[s.web[value]]
		value = s.web[value]
	}
	return value
}

@(private = "file")
find_uses :: proc(s: ^Splitter, p: ir.Program_IR) {
	for &first in s.first {
		first = max(int)
	}
	for block in s.func.blocks {
		for consumer in block.instructions {
			ir.operands(&s.func.values[consumer].variant, &s.fields)
			for field in s.fields {
				if s.web[field^] != ir.NO_VALUE && !use_kept(s, p, consumer, field) {
					s.spoiled[root(s, field^)] = true
				}
			}
		}
	}
}

// use_kept answers whether a use of a member leaves its web splittable, and notes what the use
// reads or writes.
@(private = "file")
use_kept :: proc(
	s: ^Splitter,
	p: ir.Program_IR,
	consumer: ir.Value_ID,
	field: ^ir.Value_ID,
) -> bool {
	member := field^
	web := root(s, member)
	#partial switch &v in s.func.values[consumer].variant {
	case ir.Phi:
		return s.web[consumer] != ir.NO_VALUE
	case ir.Field_Load:
		if s.loaded[web] == nil {
			layout := s.func.values[member].type.layout
			s.loaded[web] = make([]ir.Type, len(p.layouts[layout].fields), context.temp_allocator)
		}
		type := s.func.values[consumer].type
		if s.loaded[web][v.field] != ir.VOID && s.loaded[web][v.field] != type {
			return false
		}
		s.loaded[web][v.field] = type
		if s.places[consumer].block == s.places[member].block {
			s.first[member] = min(s.first[member], s.places[consumer].position)
		}
		return true
	case ir.Field_Store:
		return field == &v.cell && write(s, p, consumer, member, v.field, v.value)
	case ir.Field_Store_Ref:
		return field == &v.cell && write(s, p, consumer, member, v.field, v.value)
	}
	return false
}

@(private = "file")
write :: proc(
	s: ^Splitter,
	p: ir.Program_IR,
	store, cell: ir.Value_ID,
	field: i32,
	value: ir.Value_ID,
) -> bool {
	alloc, is_alloc := s.func.values[cell].variant.(ir.Alloc)
	if !is_alloc || s.places[store].block != s.places[cell].block {
		return false
	}
	if s.parts[cell] == nil {
		s.parts[cell] = make(
			[]ir.Value_ID,
			len(p.layouts[alloc.layout].fields),
			context.temp_allocator,
		)
		slice.fill(s.parts[cell], ir.NO_VALUE)
	}
	if s.parts[cell][field] != ir.NO_VALUE {
		return false
	}
	s.parts[cell][field] = value
	return true
}

// check_writes wants every Alloc of a web written before its first read in its own block, and each
// field the web reads written with a value of the type the reads answer. It answers whether some
// web is still splittable.
@(private = "file")
check_writes :: proc(s: ^Splitter) -> bool {
	for instruction, id in s.func.values {
		if _, is_alloc := instruction.variant.(ir.Alloc); !is_alloc || s.web[id] == ir.NO_VALUE {
			continue
		}
		web := root(s, ir.Value_ID(id))
		for field, i in s.loaded[web] {
			if field == ir.VOID {
				continue
			}
			if s.parts[id] == nil || s.parts[id][i] == ir.NO_VALUE {
				s.spoiled[web] = true
				break
			}
			if s.func.values[s.parts[id][i]].type != field {
				s.spoiled[web] = true
				break
			}
		}
	}
	for instruction, id in s.func.values {
		store_cell := ir.NO_VALUE
		#partial switch v in instruction.variant {
		case ir.Field_Store:
			store_cell = v.cell
		case ir.Field_Store_Ref:
			store_cell = v.cell
		}
		if store_cell == ir.NO_VALUE || s.web[store_cell] == ir.NO_VALUE {
			continue
		}
		if s.places[id].block != ir.NO_BLOCK && s.places[id].position > s.first[store_cell] {
			s.spoiled[root(s, store_cell)] = true
		}
	}
	for _, id in s.func.values {
		if s.web[id] != ir.NO_VALUE && !s.spoiled[root(s, ir.Value_ID(id))] {
			return true
		}
	}
	return false
}

@(private = "file")
take_apart :: proc(s: ^Splitter, allocator: runtime.Allocator) {
	count := len(s.func.values)
	values := make([dynamic]ir.Instruction, 0, count + count / 4, allocator)
	append(&values, ..s.func.values)
	replace := make([]ir.Value_ID, count, context.temp_allocator)
	slice.fill(replace, ir.NO_VALUE)
	gone := make([]bool, count, context.temp_allocator)

	// The phis of fields first, so that a phi's edges can name those of another phi.
	for instruction, id in s.func.values {
		if _, is_phi := instruction.variant.(ir.Phi); !is_phi || !splits(s, ir.Value_ID(id)) {
			continue
		}
		loaded := s.loaded[root(s, ir.Value_ID(id))]
		s.parts[id] = make([]ir.Value_ID, len(loaded), context.temp_allocator)
		for type, field in loaded {
			s.parts[id][field] = ir.NO_VALUE
			if type != ir.VOID {
				append(
					&values,
					ir.Instruction{span = instruction.span, type = type, variant = ir.Phi{}},
				)
				s.parts[id][field] = ir.Value_ID(len(values) - 1)
			}
		}
	}
	for instruction, id in s.func.values {
		// A value of no block may read a field nothing wrote.
		if s.places[id].block == ir.NO_BLOCK {
			continue
		}
		#partial switch v in instruction.variant {
		case ir.Phi:
			if !splits(s, ir.Value_ID(id)) {
				continue
			}
			gone[id] = true
			for part, field in s.parts[id] {
				if part == ir.NO_VALUE {
					continue
				}
				incoming := make([]ir.Incoming, len(v.incoming), allocator)
				for edge, i in v.incoming {
					incoming[i] = {
						block = edge.block,
						value = s.parts[edge.value][field],
					}
				}
				values[part].variant = ir.Phi {
					incoming = incoming,
				}
			}
		case ir.Alloc:
			gone[id] = splits(s, ir.Value_ID(id))
		case ir.Field_Load:
			if splits(s, v.cell) {
				gone[id] = true
				replace[id] = s.parts[v.cell][v.field]
			}
		case ir.Field_Store:
			gone[id] = splits(s, v.cell)
		case ir.Field_Store_Ref:
			gone[id] = splits(s, v.cell)
		}
	}

	for &instruction in values {
		ir.operands(&instruction.variant, &s.fields)
		for field in s.fields {
			field^ = resolved(replace, field^)
		}
	}
	for &block in s.func.blocks {
		if !has_gone(gone, block.instructions) {
			continue
		}
		list := make([dynamic]ir.Value_ID, 0, len(block.instructions), allocator)
		for value in block.instructions {
			if !gone[value] {
				append(&list, value)
				continue
			}
			if _, is_phi := values[value].variant.(ir.Phi); is_phi {
				for part in s.parts[value] {
					if part != ir.NO_VALUE {
						append(&list, part)
					}
				}
			}
		}
		block.instructions = list[:]
	}
	s.func.values = values[:]
}

@(private = "file")
has_gone :: proc(gone: []bool, values: []ir.Value_ID) -> bool {
	for value in values {
		if gone[value] {
			return true
		}
	}
	return false
}

@(private = "file")
splits :: proc(s: ^Splitter, value: ir.Value_ID) -> bool {
	return s.web[value] != ir.NO_VALUE && !s.spoiled[root(s, value)]
}
