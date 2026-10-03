package codegen

import "core:fmt"

import "../abi"
import "../ir"
import "../llvm"

@(private)
Body :: struct {
	func:      ir.Func,
	function:  llvm.LLVMValueRef,
	blocks:    []llvm.LLVMBasicBlockRef, // by ir.Block_ID; nil when the block cannot be reached
	// tails holds, by ir.Block_ID, the LLVM block the IR block ends in. An instruction that branches
	// inside, a bounds check or a Reserve, splits the block it stands in, so a phi's edge names the
	// tail and a jump names the head.
	tails:     []llvm.LLVMBasicBlockRef,
	values:    []llvm.LLVMValueRef, // by ir.Value_ID
	// rest_slot holds the values of a Rest parameter (abi.C_Type.Rest), room for the widest call of
	// the function; nil in a function that makes none. The runtime is done with them when the call
	// returns, so one slot serves every call.
	rest_slot: llvm.LLVMValueRef,
	// cells holds, by ir.Value_ID, the slot of a stack cell. Every evaluation starts it afresh: opt
	// proved nothing still points into it by then.
	cells:     []Stack_Cell,
}

@(private)
Stack_Cell :: struct {
	slot: llvm.LLVMValueRef,
	size: int,
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

	// Reverse post-order puts a definition before the uses it dominates. An unreachable block stays
	// out: nothing promises that its operands dominate their uses, and LLVM would refuse it.
	order := ir.make_flow(func, context.temp_allocator).order
	// Every block exists before any instruction does, so a jump forward and a back edge both have
	// something to name.
	for block in order {
		name: cstring = "entry" if block == ir.ENTRY else fmt.ctprintf("b%d", block)
		body.blocks[block] = llvm.LLVMAppendBasicBlockInContext(m.ctx, body.function, name)
	}
	// At the head of the entry block: an alloca anywhere else takes more stack at every pass of a
	// loop through it.
	if capacity := rest_capacity(func); capacity > 0 {
		llvm.LLVMPositionBuilderAtEnd(m.builder, body.blocks[ir.ENTRY])
		values := llvm.LLVMArrayType2(m.types.tagged, u64(capacity))
		body.rest_slot = llvm.LLVMBuildAlloca(m.builder, values, "")
	}
	body.cells = make([]Stack_Cell, len(func.values), context.temp_allocator)
	for &instruction, id in func.values {
		place := ir.cell_place(&instruction.variant)
		if place == nil || place^ != .Stack {
			continue
		}
		size, _ := ir.cell_size(m.program^, func, ir.Value_ID(id))
		llvm.LLVMPositionBuilderAtEnd(m.builder, body.blocks[ir.ENTRY])
		bytes := llvm.LLVMArrayType2(m.types.int8, u64(size))
		slot := llvm.LLVMBuildAlloca(m.builder, bytes, "")
		llvm.LLVMSetAlignment(slot, STACK_CELL_ALIGNMENT)
		body.cells[id] = {slot, size}
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

// STACK_CELL_ALIGNMENT is twice what a cell needs (abi.CLASS_SIZE): the frame is 16-byte aligned
// anyway, and the memset that starts the cell may use aligned vector stores.
@(private)
STACK_CELL_ALIGNMENT :: 16

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
