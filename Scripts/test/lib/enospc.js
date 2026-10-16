// Preloaded with `node -r` by contract-test.sh: a disk with no space left.
// Every file write fails the way a full volume fails it — ENOSPC — while the
// process's own stdout and stderr still work, because those are not on the disk.
"use strict";
const fs = require("fs");
const full = (call) => {
  const e = new Error("ENOSPC: no space left on device, " + call);
  e.code = "ENOSPC"; e.errno = -28; e.syscall = call;
  return e;
};
fs.writeFileSync = () => { throw full("write"); };
fs.appendFileSync = () => { throw full("write"); };
const writeSync = fs.writeSync;
fs.writeSync = (fd, ...rest) => {
  if (fd === 1 || fd === 2) return writeSync(fd, ...rest);
  throw full("write");
};
