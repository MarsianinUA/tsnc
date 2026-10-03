// The Go twin of bench/ts/closures/main.ts.
package main

import "fmt"

const counters = 100
const rounds = 200000
const made = 4000000
const applied = 10000000

func counter(step int) func() int {
	count := 0
	return func() int {
		count += step
		return count
	}
}

func compose(f, g func(int) int) func(int) int {
	return func(x int) int { return g(f(x)) }
}

func apply(times int, f func(int) int, start int) int {
	value := start
	for i := 0; i < times; i++ {
		value = f(value)
	}
	return value
}

func main() {
	var list []func() int
	for i := 0; i < counters; i++ {
		list = append(list, counter(i%7+1))
	}
	total := 0
	for round := 0; round < rounds; round++ {
		for _, c := range list {
			total += c()
		}
	}

	sum := 0
	for i := 0; i < made; i++ {
		add := func(y int) int { return y + i }
		sum += add(i % 10)
	}

	twice := compose(
		func(x int) int { return x + 1 },
		func(x int) int { return x * 2 % 1000003 },
	)
	fmt.Println(total, sum, apply(applied, twice, 1))
}
