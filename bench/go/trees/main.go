// The Go twin of bench/ts/trees/main.ts.
package main

import "fmt"

type Tree struct {
	left, right *Tree
}

const maxDepth = 17

func build(depth int) *Tree {
	if depth == 0 {
		return &Tree{}
	}
	return &Tree{build(depth - 1), build(depth - 1)}
}

func check(tree *Tree) int {
	if tree == nil {
		return 0
	}
	return 1 + check(tree.left) + check(tree.right)
}

func main() {
	longLived := build(maxDepth)
	for depth := 4; depth <= maxDepth; depth += 2 {
		iterations := 1 << (maxDepth - depth + 4)
		nodes := 0
		for i := 0; i < iterations; i++ {
			nodes += check(build(depth))
		}
		fmt.Println(iterations, depth, nodes)
	}
	fmt.Println(maxDepth, check(longLived))
}
