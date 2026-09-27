export function sum(xs: number[]): number {
  return xs.reduce((total, x) => total + x, 0);
}

export function words(text: string): string[] {
  return text.split(" ");
}
