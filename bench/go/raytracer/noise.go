// The Go twin of bench/ts/raytracer/noise.ts.
package main

import "math"

var perm []int

func initNoise() {
	p := make([]int, 256)
	for i := range p {
		p[i] = i
	}
	for i := 255; i > 0; i-- {
		j := nextInt() % (i + 1)
		p[i], p[j] = p[j], p[i]
	}
	perm = make([]int, 512)
	for i := range perm {
		perm[i] = p[i&255]
	}
}

func fade(t float64) float64 {
	return t * t * t * (float64(t*(float64(t*6)-15)) + 10)
}

func mix(t, a, b float64) float64 {
	return a + float64(t*(b-a))
}

func grad(hash int, x, y, z float64) float64 {
	switch hash & 15 {
	case 0:
		return x + y
	case 1:
		return -x + y
	case 2:
		return x - y
	case 3:
		return -x - y
	case 4:
		return x + z
	case 5:
		return -x + z
	case 6:
		return x - z
	case 7:
		return -x - z
	case 8:
		return y + z
	case 9:
		return -y + z
	case 10:
		return y - z
	case 11:
		return -y - z
	case 12:
		return y + x
	case 13:
		return -y + z
	case 14:
		return y - x
	}
	return -y - z
}

func noise(x, y, z float64) float64 {
	fx := math.Floor(x)
	fy := math.Floor(y)
	fz := math.Floor(z)
	cx := int(fx) & 255
	cy := int(fy) & 255
	cz := int(fz) & 255
	dx := x - fx
	dy := y - fy
	dz := z - fz
	u := fade(dx)
	v := fade(dy)
	w := fade(dz)
	a := perm[cx] + cy
	aa := perm[a] + cz
	ab := perm[a+1] + cz
	b := perm[cx+1] + cy
	ba := perm[b] + cz
	bb := perm[b+1] + cz
	near := mix(v,
		mix(u, grad(perm[aa], dx, dy, dz), grad(perm[ba], dx-1, dy, dz)),
		mix(u, grad(perm[ab], dx, dy-1, dz), grad(perm[bb], dx-1, dy-1, dz)))
	far := mix(v,
		mix(u, grad(perm[aa+1], dx, dy, dz-1), grad(perm[ba+1], dx-1, dy, dz-1)),
		mix(u, grad(perm[ab+1], dx, dy-1, dz-1), grad(perm[bb+1], dx-1, dy-1, dz-1)))
	return mix(w, near, far)
}

func fbm(p Vec, octaves int) float64 {
	sum := 0.0
	amplitude := 1.0
	frequency := 1.0
	for i := 0; i < octaves; i++ {
		sum += float64(amplitude * noise(p.x*frequency, p.y*frequency, p.z*frequency))
		amplitude *= 0.5
		frequency *= 2
	}
	return sum
}
