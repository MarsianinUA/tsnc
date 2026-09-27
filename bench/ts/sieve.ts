// The sieve of Eratosthenes over a boolean[] built by push, a few rounds: indexed reads and writes.
const LIMIT = 2000000;
const ROUNDS = 5;

let checksum = 0;
for (let round = 0; round < ROUNDS; round++) {
  const composite: boolean[] = [];
  for (let i = 0; i <= LIMIT; i++) {
    composite.push(false);
  }
  let primes = 0;
  for (let i = 2; i <= LIMIT; i++) {
    if (!composite[i]) {
      primes++;
      for (let j = i * i; j <= LIMIT; j += i) {
        composite[j] = true;
      }
    }
  }
  checksum += primes + round;
}
console.log(checksum);
