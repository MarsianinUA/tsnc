package codegen

import "core:fmt"

import "../ir"
import "../llvm"

/*
Type-based alias tags tell LLVM which loads and stores cannot touch the same memory, in Clang's
format: a root, a type node per kind of place, and on each access the tag {node, node, 0}. Places of
sibling kinds never overlap; a parent overlaps its children. A field has a node of its own, since
ir.verify reads a field only through the layout of the cell that holds it.

Under Collector sit the places a collection reads to find the references a cell holds: the header
names its table, an array's length, capacity and elements pointer bound its elements, and a
reference element is traced below the length only, while pop leaves the slot past it as it was. A
call of an abi.Effect.Allocates export carries the Collector tag, so LLVM keeps those in order with
a collection and may move any other place across it. The collector changes no live place, and it
traces every field and global: one whose store moves past the call holds zero or a live reference
meanwhile, and the new value stays in a register the conservative scan sees. A store must not move
above such a call, though: the collection could make its cell old with the value only there, and
the write barrier after the store comes too late; LLVM hoists no store above a call. Strings stay
outside since generated code never writes one; String_Join, which appends in place, is an Any row.

An access with no tag may touch anything: a Tagged slot, whose tag word tells the collector whether
the payload is a reference, the heap head and free slot an inline allocation takes, the zero fill
of a cell and the rest slot.
*/
@(private)
Place :: enum u8 {
	Collector,
	Header,
	Array_Length,
	Array_Capacity,
	Array_Elements,
	String,
	Number_Element,
	Boolean_Element,
	Reference_Element,
	Global,
	Closure,
}

@(private, rodata)
PLACE_NAMES := [Place]string {
	.Collector         = "collector",
	.Header            = "header",
	.Array_Length      = "array length",
	.Array_Capacity    = "array capacity",
	.Array_Elements    = "array elements",
	.String            = "string",
	.Number_Element    = "number element",
	.Boolean_Element   = "boolean element",
	.Reference_Element = "reference element",
	.Global            = "global",
	.Closure           = "closure",
}

@(private)
COLLECTED :: bit_set[Place] {
	.Header,
	.Array_Length,
	.Array_Capacity,
	.Array_Elements,
	.Reference_Element,
}

@(private)
add_alias_tags :: proc(m: ^Module) {
	TBAA :: "tbaa"
	m.tbaa = llvm.LLVMGetMDKindIDInContext(m.ctx, raw_data(string(TBAA)), len(TBAA))
	root_name := metadata_string(m, "tsnc")
	root := llvm.LLVMMDNodeInContext2(m.ctx, &root_name, 1)

	nodes: [Place]llvm.LLVMMetadataRef
	for name, place in PLACE_NAMES {
		// Collector comes first in Place, so its node exists before its children ask for it.
		parent := nodes[.Collector] if place in COLLECTED else root
		nodes[place] = type_node(m, name, parent)
		m.places[place] = access_tag(m, nodes[place])
	}

	m.field_tags = make([][]llvm.LLVMValueRef, len(m.program.layouts), context.temp_allocator)
	for layout, id in m.program.layouts {
		m.field_tags[id] = make([]llvm.LLVMValueRef, len(layout.fields), context.temp_allocator)
		for field, i in layout.fields {
			if field.kind != .Tagged {
				name := fmt.tprintf("field %d.%d", id, i)
				m.field_tags[id][i] = access_tag(m, type_node(m, name, root))
			}
		}
	}
}

// mark gives a load, a store or a call the tag of the place it touches; a nil tag leaves it free to
// touch anything.
@(private)
mark :: proc(m: ^Module, access, tag: llvm.LLVMValueRef) -> llvm.LLVMValueRef {
	if tag != nil {
		llvm.LLVMSetMetadata(access, m.tbaa, tag)
	}
	return access
}

@(private)
field_tag :: proc(m: ^Module, body: ^Body, cell: ir.Value_ID, field: i32) -> llvm.LLVMValueRef {
	return m.field_tags[body.func.values[cell].type.layout][field]
}

@(private)
element_tag :: proc(m: ^Module, body: ^Body, array: ir.Value_ID) -> llvm.LLVMValueRef {
	switch m.program.layouts[body.func.values[array].type.layout].element {
	case .Number:
		return m.places[.Number_Element]
	case .Boolean:
		return m.places[.Boolean_Element]
	case .Ref, .Ref_Or_Null, .Ref_Or_Undefined, .Any_Ref, .Any_Ref_Or_Null, .Any_Ref_Or_Undefined:
		return m.places[.Reference_Element]
	case .Tagged:
		return nil
	}
	unreachable()
}

@(private)
global_tag :: proc(m: ^Module, type: ir.Type) -> llvm.LLVMValueRef {
	return nil if type.kind == .Tagged else m.places[.Global]
}

// length_place tells the length of a string from that of an array, which sit at one offset.
@(private)
length_place :: proc(type: ir.Type) -> Place {
	return .String if type == ir.STR else .Array_Length
}

@(private)
type_node :: proc(m: ^Module, name: string, parent: llvm.LLVMMetadataRef) -> llvm.LLVMMetadataRef {
	operands := [?]llvm.LLVMMetadataRef{metadata_string(m, name), parent, zero_offset(m)}
	return llvm.LLVMMDNodeInContext2(m.ctx, &operands[0], len(operands))
}

@(private)
access_tag :: proc(m: ^Module, node: llvm.LLVMMetadataRef) -> llvm.LLVMValueRef {
	operands := [?]llvm.LLVMMetadataRef{node, node, zero_offset(m)}
	return llvm.LLVMMetadataAsValue(
		m.ctx,
		llvm.LLVMMDNodeInContext2(m.ctx, &operands[0], len(operands)),
	)
}

@(private)
metadata_string :: proc(m: ^Module, text: string) -> llvm.LLVMMetadataRef {
	return llvm.LLVMMDStringInContext2(m.ctx, raw_data(text), len(text))
}

@(private)
zero_offset :: proc(m: ^Module) -> llvm.LLVMMetadataRef {
	return llvm.LLVMValueAsMetadata(llvm.LLVMConstInt(m.types.int64, 0, false))
}
