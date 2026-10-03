// The Go twin of bench/ts/chars/main.ts.
package main

import (
	"fmt"
	"strings"
)

const words = 200000
const rounds = 10
const letters = "abcdefghijklmnopqrstuvwxyz"

var seed = 42

func next() int {
	seed = seed * 16807 % 2147483647
	return seed
}

func main() {
	var list []string
	for i := 0; i < words; i++ {
		word := ""
		length := 1 + next()%9
		for k := 0; k < length; k++ {
			j := next() % 26
			word += letters[j : j+1]
		}
		list = append(list, word)
	}
	text := strings.Join(list, " ")

	checksum := 0
	for round := 0; round < rounds; round++ {
		count, longest, run, vowels := 1, 0, 0, 0
		for i := 0; i < len(text); i++ {
			c := text[i]
			if c == ' ' {
				count++
				if run > longest {
					longest = run
				}
				run = 0
			} else {
				run++
				if c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u' {
					vowels++
				}
			}
		}
		es := 0
		for _, c := range text {
			if c == 'e' {
				es++
			}
		}
		checksum += count + longest + vowels + es + round
	}
	fmt.Println(len(text), checksum)
}
