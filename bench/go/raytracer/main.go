// The Go twin of bench/ts/raytracer/main.ts.
package main

import (
	"fmt"
	"strconv"
	"strings"
)

const width = 128
const height = 96
const samples = 2
const frames = 3

func main() {
	reseed(2026)
	initNoise()
	scene := parseScene(sceneText)
	fmt.Printf("scene: %d materials, %d solids, %d moving, %d planes, %d lights\n",
		len(scene.materials), len(scene.solids), len(scene.movers), len(scene.planes), len(scene.lights))

	total := 0
	var last []int
	for frame := 0; frame < frames; frame++ {
		solids := append([]Solid(nil), scene.solids...)
		for _, mover := range scene.movers {
			s := mover.sphere
			solids = append(solids, &Sphere{addScaled(s.center, mover.velocity, float64(frame)), s.radius, s.material})
		}
		stats.nodes = 0
		root := buildBvh(solids)
		pixels := renderFrame(scene, root, width, height, samples)
		sum := checksum(pixels)
		fmt.Printf("frame %d: %d nodes, checksum %d\n", frame, stats.nodes, sum)
		total = (total*31 + sum) % 1000000007
		last = pixels
	}

	var counts []string
	for _, count := range histogram(last, 8) {
		counts = append(counts, strconv.Itoa(count))
	}
	fmt.Printf("histogram: %s\n", strings.Join(counts, " "))
	for _, line := range preview(last, width, height, 32, 16) {
		fmt.Println(line)
	}
	fmt.Printf("rays: %d, shadow rays: %d, box tests: %d, shape tests: %d\n",
		stats.rays, stats.shadowRays, stats.boxTests, stats.shapeTests)
	fmt.Printf("checksum: %d\n", total)
}
