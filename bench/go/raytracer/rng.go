// The Go twin of bench/ts/raytracer/rng.ts.
package main

var seed = 1

func reseed(value int) {
	seed = value
}

func nextInt() int {
	seed = seed * 16807 % 2147483647
	return seed
}

func nextFloat() float64 {
	return float64(nextInt()-1) / 2147483646
}
