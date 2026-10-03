// The Go twin of bench/ts/raytracer/shapes.ts.
package main

import "math"

type Hit struct {
	t        float64
	point    Vec
	normal   Vec
	material *Material
}

type Box struct {
	min, max Vec
}

type Shape interface {
	hit(ray Ray, tMax float64) (Hit, bool)
}

type Solid interface {
	Shape
	bounds() Box
	centroid() Vec
}

type Sphere struct {
	center   Vec
	radius   float64
	material *Material
}

type Plane struct {
	normal   Vec
	offset   float64
	material *Material
}

type Triangle struct {
	a, e1, e2, na, nb, nc Vec
	material              *Material
}

const tMin = 1e-4

func newTriangle(a, b, c, na, nb, nc Vec, material *Material) *Triangle {
	return &Triangle{a, sub(b, a), sub(c, a), na, nb, nc, material}
}

func intersect(shape Shape, ray Ray, tMax float64) (Hit, bool) {
	stats.shapeTests++
	return shape.hit(ray, tMax)
}

func (s *Sphere) hit(ray Ray, tMax float64) (Hit, bool) {
	oc := sub(ray.origin, s.center)
	b := dot(oc, ray.dir)
	c := dot(oc, oc) - float64(s.radius*s.radius)
	disc := float64(b*b) - c
	if disc < 0 {
		return Hit{}, false
	}
	root := math.Sqrt(disc)
	t := -b - root
	if t <= tMin || t >= tMax {
		t = -b + root
		if t <= tMin || t >= tMax {
			return Hit{}, false
		}
	}
	point := at(ray, t)
	return Hit{t, point, scale(sub(point, s.center), 1/s.radius), s.material}, true
}

func (plane *Plane) hit(ray Ray, tMax float64) (Hit, bool) {
	denom := dot(plane.normal, ray.dir)
	if math.Abs(denom) < 1e-9 {
		return Hit{}, false
	}
	t := (plane.offset - dot(plane.normal, ray.origin)) / denom
	if t <= tMin || t >= tMax {
		return Hit{}, false
	}
	return Hit{t, at(ray, t), plane.normal, plane.material}, true
}

func (tri *Triangle) hit(ray Ray, tMax float64) (Hit, bool) {
	p := cross(ray.dir, tri.e2)
	det := dot(tri.e1, p)
	if det > -1e-12 && det < 1e-12 {
		return Hit{}, false
	}
	inv := 1 / det
	s := sub(ray.origin, tri.a)
	u := dot(s, p) * inv
	if u < 0 || u > 1 {
		return Hit{}, false
	}
	q := cross(s, tri.e1)
	v := dot(ray.dir, q) * inv
	if v < 0 || u+v > 1 {
		return Hit{}, false
	}
	t := dot(tri.e2, q) * inv
	if t <= tMin || t >= tMax {
		return Hit{}, false
	}
	w := 1 - u - v
	normal := normalize(addScaled(addScaled(scale(tri.na, w), tri.nb, u), tri.nc, v))
	return Hit{t, at(ray, t), normal, tri.material}, true
}

func (s *Sphere) bounds() Box {
	r := vec(s.radius, s.radius, s.radius)
	return Box{sub(s.center, r), add(s.center, r)}
}

func (s *Sphere) centroid() Vec {
	return s.center
}

func (tri *Triangle) bounds() Box {
	b := add(tri.a, tri.e1)
	c := add(tri.a, tri.e2)
	return Box{minVec(minVec(tri.a, b), c), maxVec(maxVec(tri.a, b), c)}
}

func (tri *Triangle) centroid() Vec {
	return addScaled(tri.a, add(tri.e1, tri.e2), 1.0/3)
}
