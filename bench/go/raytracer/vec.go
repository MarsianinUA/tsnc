// The Go twin of bench/ts/raytracer/vec.ts. An explicit float64 conversion around a product that
// is added keeps Go from fusing the two, which JavaScript never does.
package main

import "math"

type Vec struct {
	x, y, z float64
}

type Ray struct {
	origin, dir Vec
}

func vec(x, y, z float64) Vec {
	return Vec{x, y, z}
}

func add(a, b Vec) Vec {
	return Vec{a.x + b.x, a.y + b.y, a.z + b.z}
}

func sub(a, b Vec) Vec {
	return Vec{a.x - b.x, a.y - b.y, a.z - b.z}
}

func mul(a, b Vec) Vec {
	return Vec{a.x * b.x, a.y * b.y, a.z * b.z}
}

func scale(a Vec, s float64) Vec {
	return Vec{a.x * s, a.y * s, a.z * s}
}

func addScaled(a, b Vec, s float64) Vec {
	return Vec{a.x + float64(b.x*s), a.y + float64(b.y*s), a.z + float64(b.z*s)}
}

func negate(a Vec) Vec {
	return Vec{-a.x, -a.y, -a.z}
}

func dot(a, b Vec) float64 {
	return float64(a.x*b.x) + float64(a.y*b.y) + float64(a.z*b.z)
}

func cross(a, b Vec) Vec {
	return Vec{
		float64(a.y*b.z) - float64(a.z*b.y),
		float64(a.z*b.x) - float64(a.x*b.z),
		float64(a.x*b.y) - float64(a.y*b.x),
	}
}

func length(a Vec) float64 {
	return math.Sqrt(dot(a, a))
}

func normalize(a Vec) Vec {
	l := length(a)
	return Vec{a.x / l, a.y / l, a.z / l}
}

func lerp(a, b Vec, t float64) Vec {
	return addScaled(a, sub(b, a), t)
}

func minVec(a, b Vec) Vec {
	return Vec{min(a.x, b.x), min(a.y, b.y), min(a.z, b.z)}
}

func maxVec(a, b Vec) Vec {
	return Vec{max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)}
}

func component(a Vec, axis int) float64 {
	switch axis {
	case 0:
		return a.x
	case 1:
		return a.y
	}
	return a.z
}

func at(ray Ray, t float64) Vec {
	return addScaled(ray.origin, ray.dir, t)
}

func reflect(d, n Vec) Vec {
	return addScaled(d, n, -2*dot(d, n))
}

func refract(d, n Vec, eta float64) (Vec, bool) {
	cosi := -dot(d, n)
	k := 1 - float64(eta*eta*(1-float64(cosi*cosi)))
	if k < 0 {
		return Vec{}, false
	}
	return addScaled(scale(d, eta), n, float64(eta*cosi)-math.Sqrt(k)), true
}
