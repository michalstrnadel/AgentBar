// Whether a shell command runs tests: `test`, `tests` or `pytest` as a word of it,
// words being runs of letters. The same rule as the app's AwayFailure.isTestRun,
// and Tests/Fixtures/test-run/cases.json holds the two to it. Its own file so the
// fixture test can load it without starting a hook (update.js reads stdin and exits).
"use strict";

const isTestRun = (command) =>
  typeof command === "string" &&
  command.toLowerCase().split(/[^\p{L}]+/u).some((w) => w === "test" || w === "tests" || w === "pytest");

module.exports = { isTestRun };
