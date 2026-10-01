package ir

/*
The control flow of one function: the predecessors of every block, the blocks the entry reaches in
reverse post-order, and the dominator tree. verify asks it where a definition reaches, opt where a
condition holds.

A malformed function still gets an answer: a target outside the function adds no edge and a block
without a terminator has no successors, so the verifier can report what it finds rather than stop.
*/

Flow :: struct {
	preds: [][]Block_ID, // the predecessor edges of each block, duplicates included
	order: []Block_ID, // the blocks the entry reaches, in reverse post-order
	rank:  []i32, // the place of each block in order, -1 when the entry never reaches it
	idom:  []Block_ID, // the immediate dominator of each block; ENTRY's is ENTRY, NO_BLOCK unreached
}

@(require_results)
make_flow :: proc(func: Func, allocator := context.allocator) -> Flow {
	count := len(func.blocks)
	flow := Flow {
		preds = make([][]Block_ID, count, allocator),
		rank  = make([]i32, count, allocator),
		idom  = make([]Block_ID, count, allocator),
	}
	edges := make([][dynamic]Block_ID, count, context.temp_allocator)
	for &list in edges {
		list = make([dynamic]Block_ID, context.temp_allocator)
	}
	for block in 0 ..< count {
		targets, successor_count := successors(func, Block_ID(block))
		for target in targets[:successor_count] {
			if int(target) < count {
				append(&edges[target], Block_ID(block))
			}
		}
	}
	for list, block in edges {
		flow.preds[block] = make([]Block_ID, len(list), allocator)
		copy(flow.preds[block], list[:])
	}
	for &rank in flow.rank {
		rank = -1
	}
	for &block in flow.idom {
		block = NO_BLOCK
	}
	if count == 0 {
		return flow
	}

	post := walk_post_order(func, context.temp_allocator)
	flow.order = make([]Block_ID, len(post), allocator)
	for block, i in post {
		flow.order[len(post) - 1 - i] = block
	}
	for block, i in flow.order {
		flow.rank[block] = i32(i)
	}

	// The iterative algorithm of Cooper, Harvey and Kennedy: every block takes the common dominator
	// of the predecessors already placed, until nothing moves.
	flow.idom[ENTRY] = ENTRY
	changed := true
	for changed {
		changed = false
		for block in flow.order[1:] {
			found := NO_BLOCK
			for pred in flow.preds[block] {
				if flow.idom[pred] == NO_BLOCK {
					continue
				}
				found = pred if found == NO_BLOCK else common_dominator(flow, pred, found)
			}
			if found != NO_BLOCK && flow.idom[block] != found {
				flow.idom[block] = found
				changed = true
			}
		}
	}
	return flow
}

// dominates says whether every path from the entry to `block` goes through `head`.
dominates :: proc(flow: Flow, head, block: Block_ID) -> bool {
	if flow.rank[head] < 0 || flow.rank[block] < 0 {
		return false
	}
	walk := block
	for {
		if walk == head {
			return true
		}
		if walk == ENTRY {
			return false
		}
		next := flow.idom[walk]
		if next == NO_BLOCK || next == walk {
			return false
		}
		walk = next
	}
}

// successors answers the blocks the terminator of `block` jumps to, a target outside the function
// included: the caller skips it, and the verifier reports it.
successors :: proc(func: Func, block: Block_ID) -> (targets: [2]Block_ID, count: int) {
	instructions := func.blocks[block].instructions
	if len(instructions) == 0 {
		return
	}
	last := instructions[len(instructions) - 1]
	if int(last) >= len(func.values) {
		return
	}
	#partial switch v in func.values[last].variant {
	case Jump:
		return {v.target, 0}, 1
	case Branch:
		return {v.then_block, v.else_block}, 2
	}
	return
}

// walk_post_order carries its own stack: a function of many blocks must not grow the machine stack.
@(private = "file")
walk_post_order :: proc(func: Func, allocator := context.allocator) -> []Block_ID {
	Frame :: struct {
		block: Block_ID,
		next:  int, // the successor to follow when this frame comes up again
	}

	count := len(func.blocks)
	post := make([dynamic]Block_ID, 0, count, allocator)
	visited := make([]bool, count, context.temp_allocator)
	stack := make([dynamic]Frame, 0, count, context.temp_allocator)

	visited[ENTRY] = true
	append(&stack, Frame{block = ENTRY})
	for len(stack) > 0 {
		top := len(stack) - 1
		targets, successor_count := successors(func, stack[top].block)
		if stack[top].next >= successor_count {
			append(&post, stack[top].block)
			pop(&stack)
			continue
		}
		target := targets[stack[top].next]
		stack[top].next += 1
		if int(target) >= count || visited[target] {
			continue
		}
		visited[target] = true
		append(&stack, Frame{block = target})
	}
	return post[:]
}

// common_dominator walks two blocks up their dominator chains until they meet, comparing them by
// rank: the block further from the entry moves first.
@(private = "file")
common_dominator :: proc(flow: Flow, left, right: Block_ID) -> Block_ID {
	left, right := left, right
	for left != right {
		for flow.rank[left] > flow.rank[right] {
			left = flow.idom[left]
		}
		for flow.rank[right] > flow.rank[left] {
			right = flow.idom[right]
		}
	}
	return left
}
