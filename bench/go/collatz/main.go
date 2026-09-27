// The Go twin of bench/ts/collatz.ts.
package main

import "fmt"

const limit = 1000000

func main() {
	total, longest, start := 0, 0, 0
	for n := 1; n < limit; n++ {
		x, steps := n, 0
		for x != 1 {
			if x%2 == 0 {
				x /= 2
			} else {
				x = 3*x + 1
			}
			steps++
		}
		total += steps
		if steps > longest {
			longest, start = steps, n
		}
	}
	fmt.Println(total, longest, start)
}
