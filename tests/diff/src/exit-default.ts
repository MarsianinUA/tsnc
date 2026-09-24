// process.exit() without a code leaves with 0, and nothing after it runs. It prints nothing first,
// for the reasons exit.ts gives; the line below the call is the one that must never show.

function stop(): never {
  process.exit();
}

let rounds = 0;
while (rounds < 3) {
  rounds++;
}
if (rounds === 3) {
  stop();
}
console.log("still running after process.exit()");
