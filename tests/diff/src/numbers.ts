// Number::toString end to end (requirements 3.1): the shortest digits that read back as the same
// double, and the two thresholds where decimal notation turns into exponential. The values are the
// ones rt/num was tested against in T4.6, now printed by a compiled program instead.

function echo(x: number): void {
  console.log(x);
}

function scale(x: number, by: number): number {
  return x * by;
}

echo(0);
echo(1);
echo(-1);
echo(0.5);
echo(100);

// Below 1e21 the text is decimal, from 1e21 up it is exponential.
echo(1e20);
echo(1e21);
echo(1.2345e21);

// And symmetrically at the small end: 1e-7 is the first that goes exponential.
echo(1e-6);
echo(1e-7);
echo(0.000001234);

echo(1.7976931348623157e308);
echo(5e-324);
echo(2.220446049250313e-16);
echo(9007199254740991);
echo(9007199254740993);
echo(123456789012345678901);
echo(0.1);
echo(scale(0.1, 3));
echo(1 / 7);
echo(NaN);
echo(Infinity);
echo(-Infinity);
