// The Go twin of bench/ts/raytracer/bvh.ts.
package main

import (
	"math"
	"slices"
)

const leafSize = 4

type Node struct {
	box         Box
	axis        int
	left, right *Node
	shapes      []Solid
}

type Entry struct {
	shape  Solid
	box    Box
	center Vec
	index  int
}

func buildBvh(shapes []Solid) *Node {
	entries := make([]Entry, len(shapes))
	for i, shape := range shapes {
		entries[i] = Entry{shape, shape.bounds(), shape.centroid(), i}
	}
	return build(entries)
}

func build(entries []Entry) *Node {
	stats.nodes++
	lo, hi := entries[0].box.min, entries[0].box.max
	low, high := entries[0].center, entries[0].center
	for _, entry := range entries {
		lo = minVec(lo, entry.box.min)
		hi = maxVec(hi, entry.box.max)
		low = minVec(low, entry.center)
		high = maxVec(high, entry.center)
	}
	box := Box{lo, hi}
	if len(entries) <= leafSize {
		shapes := make([]Solid, len(entries))
		for i, entry := range entries {
			shapes[i] = entry.shape
		}
		return &Node{box: box, shapes: shapes}
	}

	extent := sub(high, low)
	axis := 2
	if extent.x >= extent.y && extent.x >= extent.z {
		axis = 0
	} else if extent.y >= extent.z {
		axis = 1
	}
	sorted := slices.Clone(entries)
	slices.SortStableFunc(sorted, func(p, q Entry) int {
		d := component(p.center, axis) - component(q.center, axis)
		if d < 0 {
			return -1
		}
		if d > 0 {
			return 1
		}
		return p.index - q.index
	})
	mid := len(sorted) / 2
	left := build(sorted[:mid])
	right := build(sorted[mid:])
	return &Node{box: box, axis: axis, left: left, right: right}
}

func enters(box Box, origin, inv Vec, limit float64) bool {
	stats.boxTests++
	x0 := (box.min.x - origin.x) * inv.x
	x1 := (box.max.x - origin.x) * inv.x
	near := min(x0, x1)
	far := max(x0, x1)
	y0 := (box.min.y - origin.y) * inv.y
	y1 := (box.max.y - origin.y) * inv.y
	near = max(near, min(y0, y1))
	far = min(far, max(y0, y1))
	z0 := (box.min.z - origin.z) * inv.z
	z1 := (box.max.z - origin.z) * inv.z
	near = max(near, min(z0, z1))
	far = min(far, max(z0, z1))
	return near <= far && far > 0 && near < limit
}

func inverse(dir Vec) Vec {
	return vec(1/dir.x, 1/dir.y, 1/dir.z)
}

func closest(root *Node, ray Ray, tMax float64) (Hit, bool) {
	inv := inverse(ray.dir)
	stack := []*Node{root}
	var best Hit
	found := false
	limit := tMax
	for len(stack) > 0 {
		node := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if !enters(node.box, ray.origin, inv, limit) {
			continue
		}
		if node.left == nil || node.right == nil {
			for _, shape := range node.shapes {
				if hit, ok := intersect(shape, ray, limit); ok {
					best = hit
					found = true
					limit = hit.t
				}
			}
		} else if component(ray.dir, node.axis) < 0 {
			stack = append(stack, node.left, node.right)
		} else {
			stack = append(stack, node.right, node.left)
		}
	}
	return best, found
}

func occluded(root *Node, ray Ray, distance float64) bool {
	inv := inverse(ray.dir)
	stack := []*Node{root}
	for len(stack) > 0 {
		node := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if !enters(node.box, ray.origin, inv, distance) {
			continue
		}
		if node.left == nil || node.right == nil {
			for _, shape := range node.shapes {
				if _, ok := intersect(shape, ray, distance); ok {
					return true
				}
			}
		} else {
			stack = append(stack, node.left, node.right)
		}
	}
	return false
}

var infinity = math.Inf(1)
