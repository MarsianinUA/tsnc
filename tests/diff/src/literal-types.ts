// Literal types (requirements 2.2): numeric, string and boolean literals as types, alone and in
// unions, on parameters, fields, array elements and return types. At run time each is the plain
// value; `switch` and `===` narrow a union of them down to one member.

type Die = 1 | 2 | 3 | 4 | 5 | 6;
type Answer = 42;
type Direction = "up" | "down";

interface Move {
  die: Die;
  direction: Direction;
  doubled: boolean;
  final: true;
}

function answer(): Answer {
  return 42;
}

function name(die: Die): string {
  switch (die) {
    case 1:
      return "one";
    case 2:
      return "two";
    case 6:
      return "six";
    default:
      return "face " + die;
  }
}

function isSix(die: Die): string {
  if (die === 6) {
    const six: 6 = die;
    return "six is " + six;
  }
  return "not six: " + die;
}

function step(position: number, move: Move): number {
  const by = move.doubled ? move.die * 2 : move.die;
  return move.direction === "up" ? position + by : position - by;
}

function flip(direction: Direction): Direction {
  return direction === "up" ? "down" : "up";
}

const faces: Die[] = [1, 2, 3, 6];
const moves: Move[] = [
  { die: 3, direction: "up", doubled: false, final: true },
  { die: 5, direction: "down", doubled: true, final: true },
  { die: 6, direction: flip("down"), doubled: true, final: true },
];

let position = 0;
for (const move of moves) {
  position = step(position, move);
}

console.log(answer(), answer() + 1, faces.map(name), faces.map(isSix));
console.log(moves[1], position, flip("up"), flip(flip("up")));

const answers: Answer[] = [42, 42];
const directions: Direction[] = ["down", "up", "up"];
console.log(answers, directions.join(), directions.filter((d) => d === "up").length);
