// The Go twin of bench/ts/integers/main.ts.
package main

import "fmt"

const size = 1000000
const searches = 5000000
const rounds = 60

func find(a []int, key int) int {
	lo, hi := 0, len(a)-1
	for lo <= hi {
		mid := (lo + hi) >> 1
		v := a[mid]
		if v == key {
			return mid
		}
		if v < key {
			lo = mid + 1
		} else {
			hi = mid - 1
		}
	}
	return -1
}

func main() {
	var a []int
	for i := 0; i < size; i++ {
		a = append(a, i*2)
	}

	found := 0
	for i := 0; i < searches; i++ {
		found += find(a, (i*7)%(2*size))
	}

	h := 0
	for r := 0; r < rounds; r++ {
		for i := 0; i < len(a); i++ {
			h = int(int32(h*31 + a[i]))
		}
	}
	fmt.Println(found, h)
}
