const RAMP = " .:-=+*#%@";

// Integer luma, 0 to 255, of the pixel starting at index i.
function luma(pixels: number[], i: number): number {
  return (54 * pixels[i] + 183 * pixels[i + 1] + 19 * pixels[i + 2]) >> 8;
}

export function checksum(pixels: number[]): number {
  let sum = 0;
  for (const byte of pixels) {
    sum = (sum * 31 + byte) % 1000000007;
  }
  return sum;
}

export function histogram(pixels: number[], buckets: number): number[] {
  const counts: number[] = [];
  for (let b = 0; b < buckets; b++) {
    counts.push(0);
  }
  for (let i = 0; i < pixels.length; i += 3) {
    counts[Math.floor((luma(pixels, i) * buckets) / 256)] += 1;
  }
  return counts;
}

// The image in characters, one for each block of pixels; width and height must divide by columns
// and rows.
export function preview(
  pixels: number[],
  width: number,
  height: number,
  columns: number,
  rows: number,
): string[] {
  const blockWidth = width / columns;
  const blockHeight = height / rows;
  const lines: string[] = [];
  for (let row = 0; row < rows; row++) {
    let line = "";
    for (let column = 0; column < columns; column++) {
      let sum = 0;
      for (let y = row * blockHeight; y < (row + 1) * blockHeight; y++) {
        for (let x = column * blockWidth; x < (column + 1) * blockWidth; x++) {
          sum += luma(pixels, (y * width + x) * 3);
        }
      }
      const mean = Math.floor(sum / (blockWidth * blockHeight));
      line += RAMP[Math.floor((mean * RAMP.length) / 256)];
    }
    lines.push(line);
  }
  return lines;
}
