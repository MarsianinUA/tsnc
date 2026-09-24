package codegen

import "core:fmt"
import "core:slice"

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
}

// build_func stops at the first instruction codegen cannot emit and leaves the reason in the
// module.
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

	// Every block exists before any instruction does, so a jump forward and a back edge both have
	// something to name.
	order := block_order(func)
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
			if m.unsupported != "" {
				return
			}
		}
		body.tails[block] = llvm.LLVMGetInsertBlock(m.builder)
	}
	patch_phis(m, &body, phis[:])
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

// block_order answers the blocks a call can reach, in reverse post-order, so every definition is
// translated before the uses it dominates. lower leaves unreachable blocks behind - what follows a
// return or a diverging call - and they stay out: nothing promises that their operands dominate
// their uses, and LLVM would refuse them.
@(private)
block_order :: proc(func: ir.Func) -> []ir.Block_ID {
	Step :: struct {
		block: ir.Block_ID,
		next:  int, // the successor to walk when this step comes up again
	}
	seen := make([]bool, len(func.blocks), context.temp_allocator)
	order := make([dynamic]ir.Block_ID, 0, len(func.blocks), context.temp_allocator)
	stack := make([dynamic]Step, 0, len(func.blocks), context.temp_allocator)

	seen[ir.ENTRY] = true
	append(&stack, Step{block = ir.ENTRY})
	for len(stack) > 0 {
		// By index rather than by pointer: the append below may move the backing array.
		top := len(stack) - 1
		targets, count := successors(func, stack[top].block)
		if stack[top].next < count {
			target := targets[stack[top].next]
			stack[top].next += 1
			if !seen[target] {
				seen[target] = true
				append(&stack, Step{block = target})
			}
			continue
		}
		append(&order, stack[top].block)
		pop(&stack)
	}
	slice.reverse(order[:])
	return order[:]
}

// successors reads the last instruction unchecked: the verifier promises that every block ends in
// exactly one terminator.
@(private)
successors :: proc(func: ir.Func, block: ir.Block_ID) -> (targets: [2]ir.Block_ID, count: int) {
	instructions := func.blocks[block].instructions
	#partial switch v in func.values[instructions[len(instructions) - 1]].variant {
	case ir.Jump:
		return {v.target, 0}, 1
	case ir.Branch:
		return {v.then_block, v.else_block}, 2
	}
	return {}, 0
}
