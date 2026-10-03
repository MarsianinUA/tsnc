// toUpperCase and toLowerCase (the String methods of 2.2) by the full case mappings of Unicode, as
// Node's ICU applies them: a letter may become two or three, some map one way only, and the pairs
// outside the basic plane map as well. Each string prints as its units, then its upper and lower
// forms.

function units(text: string): number[] {
  const out: number[] = [];
  for (let i = 0; i < text.length; i++) {
    out.push(text.charCodeAt(i));
  }
  return out;
}

function show(text: string): void {
  console.log(units(text), units(text.toUpperCase()), units(text.toLowerCase()));
}

// Privet in Cyrillic.
show("\u041f\u0440\u0438\u0432\u0435\u0442");
// Sharp s, the ffi ligature, n after an apostrophe and iota with dialytika and tonos grow when they
// upper; capital I with dot above is the one letter that grows when it lowers.
show("\u00df");
show("\ufb03");
show("\u0149");
show("\u0390");
show("\u0130");
show("\u00df\ufb03\u0149");
// Capital sharp s has a lowercase only; alpha with prosgegrammeni and its small form both upper to
// two letters; the titlecase digraph Dz with caron goes both ways; combining ypogegrammeni uppers
// to iota.
show("\u1e9e");
show("\u1fbc");
show("\u1fb3");
show("\u01c5");
show("\u0345");
// Georgian Mkhedruli and Mtavruli, and Cherokee, whose small letters came later than the capitals.
show("\u10d0");
show("\u1c90");
show("\u13a0");
show("\uab70");
show("\u13f8");
// Deseret, outside the basic plane.
show("\u{10400}");
show("\u{10428}");
// Lone surrogates stay as they are, and so do an emoji and a digit.
show("a\ud800b\udc00");
show("\u{1F600}1");
show("Hello, World! 123");
// Text of ASCII alone takes a short path: only the letters change, not the units either side of A-Z
// and a-z, and text with no letter comes back as it was.
show("@AZ[`az{");
show("123 -_~");

// Final_Sigma: a capital sigma lowers to the final form when a cased letter comes before it and
// none after it, with case-ignorable code points skipped on both sides. U+0345 and U+02B0 are both
// cased and case-ignorable, and ignorable wins; U+00AA is cased only; a lone surrogate is neither,
// so it breaks the context.
const sigmas = [
  "\u0391\u03a3",
  "\u0391\u03a3 \u0391",
  "\u03a3",
  "\u0391\u03a3.",
  "\u0391.\u03a3",
  "\u0345\u03a3",
  "\u02b0\u03a3",
  "\u0391\u03a3\u0345\u0391",
  "\u00aa\u03a3",
  "\u0391\u03a3\u03a3",
  "\u0391\ud800\u03a3",
  "\u0391\u03a3\udc00\u0391",
  "\u{10400}\u03a3",
];
for (const text of sigmas) {
  console.log(units(text.toLowerCase()));
}
