// The Go twin of bench/ts/raytracer/mesh.ts. The edge table stays hand-made, as in the TypeScript,
// rather than a Go map.
package main

import "math"

var icosahedron = []int{
	0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8, 3,
	9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1,
}

var quads = []int{0, 2, 3, 1, 4, 5, 7, 6, 0, 1, 5, 4, 2, 6, 7, 3, 0, 4, 6, 2, 1, 3, 7, 5}

type EdgeTable struct {
	keys, values []int
	mask, count  int
}

func makeTable(size int) *EdgeTable {
	keys := make([]int, size)
	for i := range keys {
		keys[i] = -1
	}
	return &EdgeTable{keys, make([]int, size), size - 1, 0}
}

func (table *EdgeTable) slotOf(key int) int {
	slot := (key * 7919) & table.mask
	for table.keys[slot] != -1 && table.keys[slot] != key {
		slot = (slot + 1) & table.mask
	}
	return slot
}

func (table *EdgeTable) grow() {
	keys, values := table.keys, table.values
	bigger := makeTable(len(keys) * 2)
	table.keys, table.values, table.mask = bigger.keys, bigger.values, bigger.mask
	for i, key := range keys {
		if key != -1 {
			slot := table.slotOf(key)
			table.keys[slot] = key
			table.values[slot] = values[i]
		}
	}
}

func midpoint(table *EdgeTable, points *[]Vec, i, j int) int {
	key := j*65536 + i
	if i < j {
		key = i*65536 + j
	}
	slot := table.slotOf(key)
	if table.keys[slot] == key {
		return table.values[slot]
	}
	index := len(*points)
	*points = append(*points, normalize(add((*points)[i], (*points)[j])))
	table.keys[slot] = key
	table.values[slot] = index
	table.count++
	if table.count*2 > len(table.keys) {
		table.grow()
	}
	return index
}

func icosphere(center Vec, radius float64, depth int, material *Material) []*Triangle {
	t := (1 + math.Sqrt(5)) / 2
	points := []Vec{
		vec(-1, t, 0), vec(1, t, 0), vec(-1, -t, 0), vec(1, -t, 0),
		vec(0, -1, t), vec(0, 1, t), vec(0, -1, -t), vec(0, 1, -t),
		vec(t, 0, -1), vec(t, 0, 1), vec(-t, 0, -1), vec(-t, 0, 1),
	}
	for i, p := range points {
		points[i] = normalize(p)
	}
	table := makeTable(64)
	faces := icosahedron
	for level := 0; level < depth; level++ {
		var next []int
		for f := 0; f < len(faces); f += 3 {
			a, b, c := faces[f], faces[f+1], faces[f+2]
			ab := midpoint(table, &points, a, b)
			bc := midpoint(table, &points, b, c)
			ca := midpoint(table, &points, c, a)
			next = append(next, a, ab, ca, b, bc, ab, c, ca, bc, ab, bc, ca)
		}
		faces = next
	}

	var triangles []*Triangle
	for f := 0; f < len(faces); f += 3 {
		na, nb, nc := points[faces[f]], points[faces[f+1]], points[faces[f+2]]
		a := addScaled(center, na, radius)
		b := addScaled(center, nb, radius)
		c := addScaled(center, nc, radius)
		triangles = append(triangles, newTriangle(a, b, c, na, nb, nc, material))
	}
	return triangles
}

func box(lo, hi Vec, material *Material) []*Triangle {
	var corners [8]Vec
	for i := range corners {
		corners[i] = vec(hi.x, hi.y, hi.z)
		if i&1 == 0 {
			corners[i].x = lo.x
		}
		if i&2 == 0 {
			corners[i].y = lo.y
		}
		if i&4 == 0 {
			corners[i].z = lo.z
		}
	}
	var triangles []*Triangle
	for f := 0; f < len(quads); f += 4 {
		a, b, c, d := corners[quads[f]], corners[quads[f+1]], corners[quads[f+2]], corners[quads[f+3]]
		n := normalize(cross(sub(b, a), sub(c, a)))
		triangles = append(triangles, newTriangle(a, b, c, n, n, n, material), newTriangle(a, c, d, n, n, n, material))
	}
	return triangles
}

func terrain(origin Vec, size float64, cells int, height float64, material *Material) []*Triangle {
	side := cells + 1
	var points, sums []Vec
	for j := 0; j < side; j++ {
		for i := 0; i < side; i++ {
			x := origin.x + float64(i)*size/float64(cells)
			z := origin.z + float64(j)*size/float64(cells)
			y := origin.y + float64(height*fbm(vec(x*0.2, 0.37, z*0.2), 5))
			points = append(points, vec(x, y, z))
			sums = append(sums, Vec{})
		}
	}

	var faces []int
	for j := 0; j < cells; j++ {
		for i := 0; i < cells; i++ {
			p := j*side + i
			faces = append(faces, p, p+side, p+1, p+1, p+side, p+side+1)
		}
	}
	for f := 0; f < len(faces); f += 3 {
		a, b, c := faces[f], faces[f+1], faces[f+2]
		n := cross(sub(points[b], points[a]), sub(points[c], points[a]))
		sums[a] = add(sums[a], n)
		sums[b] = add(sums[b], n)
		sums[c] = add(sums[c], n)
	}

	var triangles []*Triangle
	for f := 0; f < len(faces); f += 3 {
		a, b, c := faces[f], faces[f+1], faces[f+2]
		triangles = append(triangles, newTriangle(points[a], points[b], points[c],
			normalize(sums[a]), normalize(sums[b]), normalize(sums[c]), material))
	}
	return triangles
}
