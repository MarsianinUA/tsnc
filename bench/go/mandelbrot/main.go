// The Go twin of bench/ts/mandelbrot.ts.
package main

import "fmt"

const size = 1600
const limit = 200

func inside(cr, ci float64) bool {
	zr, zi := 0.0, 0.0
	for i := 0; i < limit; i++ {
		// An explicit conversion keeps Go from fusing a multiply and an add, which JavaScript never does.
		rr := float64(zr * zr)
		ii := float64(zi * zi)
		if rr+ii > 4 {
			return false
		}
		zi = float64(2*zr*zi) + ci
		zr = rr - ii + cr
	}
	return true
}

func main() {
	count := 0
	for y := 0; y < size; y++ {
		ci := float64(2*y)/size - 1
		for x := 0; x < size; x++ {
			cr := float64(3*x)/size - 2
			if inside(cr, ci) {
				count++
			}
		}
	}
	fmt.Println(count)
}
