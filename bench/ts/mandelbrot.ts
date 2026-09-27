// The points of a grid that stay in the Mandelbrot set: an f64 kernel of + - * and a compare, with
// no `%` and no indexing.
const SIZE = 1600;
const LIMIT = 200;

function inside(cr: number, ci: number): boolean {
  let zr = 0;
  let zi = 0;
  for (let i = 0; i < LIMIT; i++) {
    const rr = zr * zr;
    const ii = zi * zi;
    if (rr + ii > 4) {
      return false;
    }
    zi = 2 * zr * zi + ci;
    zr = rr - ii + cr;
  }
  return true;
}

let count = 0;
for (let y = 0; y < SIZE; y++) {
  const ci = (2 * y) / SIZE - 1;
  for (let x = 0; x < SIZE; x++) {
    const cr = (3 * x) / SIZE - 2;
    if (inside(cr, ci)) {
      count++;
    }
  }
}
console.log(count);
