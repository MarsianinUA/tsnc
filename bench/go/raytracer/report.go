// The Go twin of bench/ts/raytracer/report.ts.
package main

const ramp = " .:-=+*#%@"

func luma(pixels []int, i int) int {
	return (54*pixels[i] + 183*pixels[i+1] + 19*pixels[i+2]) >> 8
}

func checksum(pixels []int) int {
	sum := 0
	for _, b := range pixels {
		sum = (sum*31 + b) % 1000000007
	}
	return sum
}

func histogram(pixels []int, buckets int) []int {
	counts := make([]int, buckets)
	for i := 0; i < len(pixels); i += 3 {
		counts[luma(pixels, i)*buckets/256]++
	}
	return counts
}

func preview(pixels []int, width, height, columns, rows int) []string {
	blockWidth := width / columns
	blockHeight := height / rows
	var lines []string
	for row := 0; row < rows; row++ {
		line := ""
		for column := 0; column < columns; column++ {
			sum := 0
			for y := row * blockHeight; y < (row+1)*blockHeight; y++ {
				for x := column * blockWidth; x < (column+1)*blockWidth; x++ {
					sum += luma(pixels, (y*width+x)*3)
				}
			}
			mean := sum / (blockWidth * blockHeight)
			line += string(ramp[mean*len(ramp)/256])
		}
		lines = append(lines, line)
	}
	return lines
}
