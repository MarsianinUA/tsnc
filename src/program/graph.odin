#+private
/*
The module graph: the order the modules initialize in, and the rings they form.

Both come out of one depth-first search, Tarjan's strongly connected components, over the edges
that carry a value (an `import type` edge is erased before the program runs, so it orders nothing).
A component leaves the search only once every component it points at has left, so the order the
components come out in is already the initialization order: a module lands after everything it
imports. A component of two or more modules is a ring.

The search is a loop over an explicit stack rather than a recursive procedure, because its depth is
the number of files in the program, and parse bounds its own recursion for the same reason.
*/
package program

import "base:runtime"
import "core:slice"
import "core:strings"

import "../bind"
import "../diag"
import "../source"

// UNVISITED is free to be a marker: modules are numbered from zero as they are discovered, so no
// module ever carries this number.
UNVISITED :: i32(-1)

// Frame is one module on the depth-first stack, with the edge of it to look at next.
Frame :: struct {
	module: source.File_ID,
	edge:   int,
}

// Search keeps Tarjan's two numbers per module in index and low: when they are equal the module is
// the root of a component. pending holds the modules of the components still being built, and order
// and groups are the result.
Search :: struct {
	bound:     []bind.Bound_File,
	imports:   [][]Import_Edge,
	allocator: runtime.Allocator, // where the result lives; everything else is scratch
	index:     []i32,
	low:       []i32,
	on_stack:  []bool,
	pending:   [dynamic]source.File_ID,
	work:      [dynamic]Frame,
	order:     [dynamic]source.File_ID,
	groups:    [dynamic]Cycle,
	next:      i32,
}

// search_modules takes roots in File_ID order and each module's edges in source order, so two runs
// of one program give one answer.
search_modules :: proc(
	bound: []bind.Bound_File,
	imports: [][]Import_Edge,
	allocator: runtime.Allocator,
) -> (
	init_order: []source.File_ID,
	cycles: []Cycle,
) {
	count := len(bound)
	s := Search {
		bound     = bound,
		imports   = imports,
		allocator = allocator,
		index     = make([]i32, count, context.temp_allocator),
		low       = make([]i32, count, context.temp_allocator),
		on_stack  = make([]bool, count, context.temp_allocator),
		pending   = make([dynamic]source.File_ID, 0, count, context.temp_allocator),
		work      = make([dynamic]Frame, 0, count, context.temp_allocator),
		order     = make([dynamic]source.File_ID, 0, count, allocator),
		groups    = make([dynamic]Cycle, allocator),
	}
	slice.fill(s.index, UNVISITED)

	for root in 0 ..< count {
		if s.index[root] != UNVISITED {
			continue
		}
		discover(&s, source.File_ID(root))
		walk(&s)
	}
	return s.order[:], s.groups[:]
}

walk :: proc(s: ^Search) {
	for len(s.work) > 0 {
		top := len(s.work) - 1
		frame := s.work[top]
		edges := s.imports[frame.module]

		if frame.edge < len(edges) {
			// Step over the edge before anything can push a frame: appending to work may move it,
			// so an index is the only safe way to hold a place in it.
			s.work[top].edge += 1
			follow(s, frame.module, edges[frame.edge])
			continue
		}

		pop(&s.work)
		if len(s.work) > 0 {
			parent := s.work[len(s.work) - 1].module
			s.low[parent] = min(s.low[parent], s.low[frame.module])
		}
		if s.low[frame.module] == s.index[frame.module] {
			close_component(s, frame.module)
		}
	}
}

// follow takes one edge out of `module`: it opens the module the edge names, or, when that module
// is already part of a component still being built, lowers this one onto it.
follow :: proc(s: ^Search, module: source.File_ID, edge: Import_Edge) {
	if edge.type_only {
		return
	}
	if s.index[edge.module] == UNVISITED {
		discover(s, edge.module)
		return
	}
	if s.on_stack[edge.module] {
		s.low[module] = min(s.low[module], s.index[edge.module])
	}
}

discover :: proc(s: ^Search, module: source.File_ID) {
	s.index[module] = s.next
	s.low[module] = s.next
	s.next += 1
	append(&s.pending, module)
	s.on_stack[module] = true
	append(&s.work, Frame{module = module})
}

// close_component finishes the component whose root is `root`: its modules are everything pending
// above the root. They take their place in the order together, in File_ID order, and a component
// of more than one module is a ring.
close_component :: proc(s: ^Search, root: source.File_ID) {
	first := len(s.pending) - 1
	for s.pending[first] != root {
		first -= 1
	}

	members := s.pending[first:]
	slice.sort(members)
	for module in members {
		s.on_stack[module] = false
	}
	append(&s.order, ..members)

	if len(members) > 1 {
		cycle := Cycle {
			modules = slice.clone(members, s.allocator),
		}
		for module in cycle.modules {
			cycle.has_effects ||= s.bound[module].has_side_effects
		}
		append(&s.groups, cycle)
	}
	resize(&s.pending, first)
}

// report_cycles treats one ring as one mistake, so a ring of five modules is one message and not
// five. The message stands on the import that closes the ring, which closing_span finds.
report_cycles :: proc(
	files: []source.File,
	cycles: []Cycle,
	imports: [][]Import_Edge,
	allocator: runtime.Allocator,
) -> []diag.Diagnostic {
	out := make([dynamic]diag.Diagnostic, allocator)
	for cycle in cycles {
		if !cycle.has_effects {
			continue
		}
		append(
			&out,
			diag.Diagnostic {
				code = .Cycle_With_Side_Effects,
				span = closing_span(cycle, imports),
				args = {0 = module_list(files, cycle.modules, allocator)},
			},
		)
	}
	return out[:]
}

// closing_span is the specifier of the import that closes the ring: the first request, in source
// order, of the ring's first module that points back into the ring. Every module of a ring imports
// another one of it, which is what makes the ring a ring, so the first module always answers and
// the walk never reaches the rest. The empty span at the end is what a procedure that must return
// something says when it has nothing: it would put the message at the start of the lib file, which
// is wrong but still a place, where a crash here would be worse.
closing_span :: proc(cycle: Cycle, imports: [][]Import_Edge) -> source.Span {
	for module in cycle.modules {
		for edge in imports[module] {
			if edge.type_only || edge.module == module {
				continue
			}
			if slice.contains(cycle.modules, edge.module) {
				return edge.span
			}
		}
	}
	return {}
}

// module_list names the modules of a ring the way the message prints them: `a.ts`, `b.ts`.
module_list :: proc(
	files: []source.File,
	modules: []source.File_ID,
	allocator: runtime.Allocator,
) -> string {
	text := strings.builder_make(allocator)
	for module, i in modules {
		if i > 0 {
			strings.write_string(&text, ", ")
		}
		strings.write_byte(&text, '`')
		strings.write_string(&text, files[module].path)
		strings.write_byte(&text, '`')
	}
	return strings.to_string(text)
}
