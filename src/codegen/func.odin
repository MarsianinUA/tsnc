package codegen

import "core:fmt"

import "../abi"
import "../ir"
import "../llvm"

@(private)
Body :: struct {
	func:        ir.Func,
	function:    llvm.LLVMValueRef,
	blocks:      []llvm.LLVMBasicBlockRef, // by ir.Block_ID; nil when the block cannot be reached
	// tails holds, by ir.Block_ID, the LLVM block the IR block ends in. A bounds check splits the
	// block it stands in, so a phi's edge names the tail and a jump names the head.
	tails:       []llvm.LLVMBasicBlockRef,
	values:      []llvm.LLVMValueRef, // by ir.Value_ID
	// result_slot is where the runtime writes a tagged result (abi.C_Type.Tagged); nil in a function
	// that calls for none. Every such call reads it back at once, so one slot serves them all.
	result_slot: llvm.LLVMValueRef,
	// rest_slot holds the values of a Rest parameter (abi.C_Type.Rest), room for the widest call of
	// the function; nil in a function that makes none. The runtime is done with them when the call
	// returns, so one slot serves every call.
	rest_slot:   llvm.LLVMValueRef,
	// cells holds, by ir.Value_ID, the stack slot of a cell opt put on the stack (ir.Cell_Place).
	// Every evaluation of the instruction starts the slot afresh: opt proved nothing still points
	// into it by then.
	cells:       []llvm.LLVMValueRef,
}

@(private)
build_func :: proc(m: ^Module, func_id: ir.Func_ID) {
	func := m.program.funcs[func_id]
	body := Body {
		func     = func,
		function = m.funcs[func_id].function,
		blocks   = make([]llvm.LLVMBasicBlockRef, len(func.blocks), context.temp_allocator),
		tails    = make([]llvm.LLVMBasicBlockRef, len(func.blocks), context.temp_allocator),
		values   = make([]llvm.LLVMValueRef, len(func.values), context.temp_allocator),
	}

	// Reverse post-order puts every definition before the uses it dominates. The blocks lower leaves
	// unreachable stay out: nothing promises that their operands dominate their uses, and LLVM would
	// refuse them.
	order := ir.make_flow(func, context.temp_allocator).order
	// Every block exists before any instruction does, so a jump forward and a back edge both have
	// something to name.
	for block in order {
		name: cstring = "entry" if block == ir.ENTRY else fmt.ctprintf("b%d", block)
		body.blocks[block] = llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, name)
	}
	// At the head of the entry block: an alloca anywhere else takes more stack at every pass of a
	// loop through it.
	if calls_for_a_tagged_result(func) {
		llvm.LLVMPositionBuilderAtEnd(m.builder, body.blocks[ir.ENTRY])
		body.result_slot = llvm.LLVMBuildAlloca(m.builder, m.types.tagged, "")
	}
	if capacity := rest_capacity(func); capacity > 0 {
		llvm.LLVMPositionBuilderAtEnd(m.builder, body.blocks[ir.ENTRY])
		values := llvm.LLVMArrayType2(m.types.tagged, u64(capacity))
		body.rest_slot = llvm.LLVMBuildAlloca(m.builder, values, "")
	}
	body.cells = make([]llvm.LLVMValueRef, len(func.values), context.temp_allocator)
	for _, id in func.values {
		if size := stack_cell_size(m, func, ir.Value_ID(id)); size > 0 {
			llvm.LLVMPositionBuilderAtEnd(m.builder, body.blocks[ir.ENTRY])
			bytes := llvm.LLVMArrayType2(m.types.int8, u64(size))
			body.cells[id] = llvm.LLVMBuildAlloca(m.builder, bytes, "")
			llvm.LLVMSetAlignment(body.cells[id], STACK_CELL_ALIGNMENT)
		}
	}

	phis := make([dynamic]ir.Value_ID, 0, len(func.blocks), context.temp_allocator)
	for block in order {
		llvm.LLVMPositionBuilderAtEnd(m.builder, body.blocks[block])
		instructions := func.blocks[block].instructions
		// Every phi of a block stands before its other instructions, so one pass over the head of
		// the block creates them all and anything below can already name them. Their edges wait
		// until every block is emitted, which is what a loop header needs to learn its back edge.
		for value in instructions {
			if _, is_phi := func.values[value].variant.(ir.Phi); !is_phi {
				break
			}
			type := value_type(m, func.values[value].type)
			body.values[value] = llvm.LLVMBuildPhi(m.builder, type, "")
			append(&phis, value)
		}
		for value in instructions {
			if _, is_phi := func.values[value].variant.(ir.Phi); is_phi {
				continue
			}
			build_instruction(m, &body, value)
		}
		body.tails[block] = llvm.LLVMGetInsertBlock(m.builder)
	}
	patch_phis(m, &body, phis[:])
}

// STACK_CELL_ALIGNMENT is what a cell gets on the heap too: its size class steps by 16 bytes.
@(private)
STACK_CELL_ALIGNMENT :: 16

@(private)
stack_cell_size :: proc(m: ^Module, func: ir.Func, value: ir.Value_ID) -> int {
	stack := false
	#partial switch v in func.values[value].variant {
	case ir.Alloc:
		stack = v.place == .Stack
	case ir.New_Array:
		stack = v.place == .Stack
	case ir.Make_Closure:
		stack = v.place == .Stack
	}
	if !stack {
		return 0
	}
	size, _ := ir.cell_size(m.program^, func, value)
	return size
}

@(private)
calls_for_a_tagged_result :: proc(func: ir.Func) -> bool {
	exports := abi.RUNTIME_EXPORTS
	for instruction in func.values {
		call, is_call := instruction.variant.(ir.Call_Runtime)
		if is_call && exports[call.export].result == .Tagged {
			return true
		}
	}
	return false
}

@(private)
rest_capacity :: proc(func: ir.Func) -> int {
	exports := abi.RUNTIME_EXPORTS
	widest := 0
	for instruction in func.values {
		call, is_call := instruction.variant.(ir.Call_Runtime)
		if !is_call {
			continue
		}
		params := exports[call.export].params
		if len(params) > 0 && params[len(params) - 1] == .Rest {
			widest = max(widest, len(call.args) - (len(params) - 1))
		}
	}
	return widest
}

// patch_phis leaves out an edge out of a block that cannot run: it is not an edge of the LLVM
// function either. An edge comes from the tail of its block, where the jump stands.
@(private)
patch_phis :: proc(m: ^Module, body: ^Body, phis: []ir.Value_ID) {
	for value in phis {
		phi := body.func.values[value].variant.(ir.Phi)
		values := make([dynamic]llvm.LLVMValueRef, 0, len(phi.incoming), context.temp_allocator)
		blocks := make(
			[dynamic]llvm.LLVMBasicBlockRef,
			0,
			len(phi.incoming),
			context.temp_allocator,
		)
		for edge in phi.incoming {
			if body.blocks[edge.block] == nil {
				continue
			}
			append(&values, body.values[edge.value])
			append(&blocks, body.tails[edge.block])
		}
		llvm.LLVMAddIncoming(
			body.values[value],
			raw_data(values[:]),
			raw_data(blocks[:]),
			u32(len(values)),
		)
	}
}
