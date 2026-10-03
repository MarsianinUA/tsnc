// The Go twin of bench/ts/raytracer/render.ts.
package main

import "math"

const maxDepth = 5
const bias = 1e-3

var black = vec(0, 0, 0)

func closestHit(scene *Scene, root *Node, ray Ray) (Hit, bool) {
	best, found := closest(root, ray, infinity)
	for _, plane := range scene.planes {
		limit := infinity
		if found {
			limit = best.t
		}
		if hit, ok := intersect(plane, ray, limit); ok {
			best, found = hit, true
		}
	}
	return best, found
}

func inShadow(scene *Scene, root *Node, ray Ray, distance float64) bool {
	stats.shadowRays++
	if occluded(root, ray, distance) {
		return true
	}
	for _, plane := range scene.planes {
		if _, ok := intersect(plane, ray, distance); ok {
			return true
		}
	}
	return false
}

func power(x float64, n int) float64 {
	result := 1.0
	base := x
	for e := n; e > 0; e >>= 1 {
		if e&1 == 1 {
			result *= base
		}
		base *= base
	}
	return result
}

func direct(scene *Scene, root *Node, hit Hit, normal, view, base Vec) Vec {
	material := hit.material
	origin := addScaled(hit.point, normal, bias)
	color := mul(base, scene.ambient)
	for _, light := range scene.lights {
		toLight := sub(light.position, origin)
		distance := length(toLight)
		l := scale(toLight, 1/distance)
		lambert := dot(normal, l)
		if lambert <= 0 || inShadow(scene, root, Ray{origin, l}, distance) {
			continue
		}
		color = addScaled(color, mul(base, light.color), lambert)
		if material.specular > 0 {
			highlight := -dot(reflect(negate(l), normal), view)
			if highlight > 0 {
				color = addScaled(color, light.color, material.specular*power(highlight, material.shininess))
			}
		}
	}
	return color
}

func bounce(scene *Scene, root *Node, origin, dir Vec, depth int) Vec {
	return trace(scene, root, Ray{origin, dir}, depth+1)
}

func shade(scene *Scene, root *Node, ray Ray, hit Hit, normal Vec, inside bool, depth int) Vec {
	material := hit.material
	outside := addScaled(hit.point, normal, bias)
	switch material.kind {
	case diffuse:
		lit := direct(scene, root, hit, normal, ray.dir, material.texture(hit.point))
		if material.reflectivity <= 0 || depth >= maxDepth {
			return lit
		}
		mirrored := bounce(scene, root, outside, reflect(ray.dir, normal), depth)
		return lerp(lit, mirrored, material.reflectivity)
	case mirror:
		lit := direct(scene, root, hit, normal, ray.dir, black)
		if depth >= maxDepth {
			return lit
		}
		mirrored := bounce(scene, root, outside, reflect(ray.dir, normal), depth)
		return add(lit, mul(material.texture(hit.point), mirrored))
	}
	lit := direct(scene, root, hit, normal, ray.dir, black)
	if depth >= maxDepth {
		return lit
	}
	tint := material.texture(hit.point)
	mirrored := bounce(scene, root, outside, reflect(ray.dir, normal), depth)
	eta := 1 / material.ior
	if inside {
		eta = material.ior
	}
	bent, ok := refract(ray.dir, normal, eta)
	if !ok {
		return add(lit, mul(tint, mirrored))
	}
	through := bounce(scene, root, addScaled(hit.point, normal, -bias), bent, depth)
	r := (1 - material.ior) / (1 + material.ior)
	f0 := r * r
	m := 1 + dot(ray.dir, normal)
	fresnel := f0 + float64((1-f0)*power(m, 5))
	return add(lit, mul(tint, lerp(through, mirrored, fresnel)))
}

func trace(scene *Scene, root *Node, ray Ray, depth int) Vec {
	stats.rays++
	hit, ok := closestHit(scene, root, ray)
	if !ok {
		return lerp(scene.horizon, scene.zenith, max(0, ray.dir.y))
	}
	inside := dot(hit.normal, ray.dir) > 0
	normal := hit.normal
	if inside {
		normal = negate(hit.normal)
	}
	color := shade(scene, root, ray, hit, normal, inside, depth)
	if hit.material.emission == nil {
		return color
	}
	return add(color, *hit.material.emission)
}

func toByte(v float64) int {
	return int(math.Floor(float64(math.Sqrt(v/(1+v))*255) + 0.5))
}

func renderFrame(scene *Scene, root *Node, width, height, samples int) []int {
	camera := scene.camera
	forward := normalize(sub(camera.target, camera.eye))
	right := normalize(cross(forward, camera.up))
	up := cross(right, forward)
	halfWidth := camera.height * float64(width) / float64(height)
	weight := 1 / float64(samples*samples)
	pixels := make([]int, 0, width*height*3)
	for py := 0; py < height; py++ {
		for px := 0; px < width; px++ {
			sum := black
			for sy := 0; sy < samples; sy++ {
				for sx := 0; sx < samples; sx++ {
					u := float64((float64(px)+(float64(sx)+nextFloat())/float64(samples))/float64(width)*2) - 1
					v := 1 - float64((float64(py)+(float64(sy)+nextFloat())/float64(samples))/float64(height)*2)
					dir := normalize(addScaled(addScaled(forward, right, u*halfWidth), up, v*camera.height))
					sum = add(sum, trace(scene, root, Ray{camera.eye, dir}, 0))
				}
			}
			color := scale(sum, weight)
			pixels = append(pixels, toByte(color.x), toByte(color.y), toByte(color.z))
		}
	}
	return pixels
}
