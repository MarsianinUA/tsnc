// The Go twin of bench/ts/sieve/main.ts.
package main

import "fmt"

const limit = 2000000
const rounds = 5

func main() {
	checksum := 0
	for round := 0; round < rounds; round++ {
		var composite []bool
		for i := 0; i <= limit; i++ {
			composite = append(composite, false)
		}
		primes := 0
		for i := 2; i <= limit; i++ {
			if !composite[i] {
				primes++
				for j := i * i; j <= limit; j += i {
					composite[j] = true
				}
			}
		}
		checksum += primes + round
	}
	fmt.Println(checksum)
}
