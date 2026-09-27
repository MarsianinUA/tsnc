// The Go twin of bench/ts/strings.ts.
package main

import (
	"fmt"
	"strconv"
	"strings"
)

const rounds = 10000
const parts = 50

var seed = 7

func next() int {
	seed = seed * 16807 % 2147483647
	return seed
}

func main() {
	checksum := 0
	for round := 0; round < rounds; round++ {
		var list []string
		for i := 0; i < parts; i++ {
			list = append(list, "item"+strconv.Itoa(next()%1000)+":"+strconv.Itoa(i))
		}
		line := strings.Join(list, ",")
		fields := strings.Split(line, ",")
		built := ""
		for _, field := range fields {
			colon := strings.Index(field, ":")
			name := strings.ToUpper(field[:colon])
			built += name[4:] + ";"
			if strings.Contains(field, "7") {
				checksum++
			}
		}
		checksum += len(built) + strings.Index(line, "item5") + len(fields)
	}
	fmt.Println(checksum)
}
