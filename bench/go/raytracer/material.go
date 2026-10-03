// The Go twin of bench/ts/raytracer/material.ts.
package main

import "math"

type Texture func(p Vec) Vec

type Kind int

const (
	diffuse Kind = iota
	mirror
	glass
)

type Material struct {
	name         string
	kind         Kind
	texture      Texture
	specular     float64
	shininess    int
	reflectivity float64
	ior          float64
	emission     *Vec
}

func solid(color Vec) Texture {
	return func(Vec) Vec { return color }
}

func checker(a, b Vec, size float64) Texture {
	return func(p Vec) Vec {
		cell := math.Floor(p.x/size) + math.Floor(p.y/size) + math.Floor(p.z/size)
		if int(cell)&1 == 0 {
			return a
		}
		return b
	}
}

func wave(x float64) float64 {
	return math.Abs(x - float64(2*math.Floor(x*0.5)) - 1)
}

func marble(a, b Vec, frequency float64) Texture {
	return func(p Vec) Vec {
		return lerp(a, b, wave(float64(p.x*frequency)+float64(4*fbm(scale(p, frequency), 4))))
	}
}

func wood(a, b Vec, frequency float64) Texture {
	return func(p Vec) Vec {
		radius := math.Sqrt(float64(p.x*p.x) + float64(p.z*p.z))
		ring := float64(radius*frequency) + float64(2*noise(p.x, p.y*4, p.z))
		return lerp(a, b, ring-math.Floor(ring))
	}
}

func strata(low, high Vec, from, to float64) Texture {
	return func(p Vec) Vec {
		h := p.y + float64(0.4*noise(p.x*3, 0.5, p.z*3))
		if h <= from {
			return low
		}
		if h >= to {
			return high
		}
		return lerp(low, high, (h-from)/(to-from))
	}
}
