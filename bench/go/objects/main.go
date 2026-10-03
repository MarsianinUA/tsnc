// The Go twin of bench/ts/objects/main.ts.
package main

import (
	"fmt"
	"slices"
	"strconv"
)

type Item struct {
	id, x, y int
	name     string
}

const count = 200000
const rounds = 3

var seed = 11

func next() int {
	seed = seed * 16807 % 2147483647
	return seed
}

func main() {
	checksum := 0
	for round := 0; round < rounds; round++ {
		var items []Item
		for i := 0; i < count; i++ {
			items = append(items, Item{id: i, x: next() % 10000, y: next() % 10000, name: "item" + strconv.Itoa(i%100)})
		}
		slices.SortStableFunc(items, func(a, b Item) int {
			if a.x != b.x {
				return a.x - b.x
			}
			return a.id - b.id
		})

		var near []Item
		for _, p := range items {
			if p.x < 5000 && p.y < 5000 {
				near = append(near, p)
			}
		}
		var sums []int
		for _, p := range near {
			sums = append(sums, p.x+p.y)
		}
		total := 0
		for _, v := range sums {
			total += v
		}
		weighted := 0
		for i := 0; i < len(items); i++ {
			weighted += items[i].id * (i % 7)
		}
		named := 0
		for _, p := range near {
			if p.name == "item42" {
				named++
			}
		}
		checksum += len(near) + total + weighted + named
	}
	fmt.Println(checksum)
}
