// Preloaded with `node -r` by contract-test.sh: a wall clock that is wrong, or
// that moves under the process. Only Date.now is bent — it is the one clock the
// hooks read.
//   CLOCK_SKEW_MS        constant offset from the real time
//   CLOCK_JUMP_AFTER_MS  after this many real ms, the clock jumps …
//   CLOCK_JUMP_MS        … by this much (negative = backwards)
"use strict";
const real = Date.now.bind(Date);
const t0 = real();
const skew = Number(process.env.CLOCK_SKEW_MS) || 0;
const after = Number(process.env.CLOCK_JUMP_AFTER_MS);
const jump = Number(process.env.CLOCK_JUMP_MS) || 0;
Date.now = () => {
  const r = real();
  return r + skew + (Number.isFinite(after) && r - t0 >= after ? jump : 0);
};
