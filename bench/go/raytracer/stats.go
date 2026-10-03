// The Go twin of bench/ts/raytracer/stats.ts.
package main

var stats struct {
	rays, shadowRays, boxTests, shapeTests, nodes int
}
