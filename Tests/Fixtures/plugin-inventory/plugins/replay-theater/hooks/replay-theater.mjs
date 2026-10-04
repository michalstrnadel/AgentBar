  on("session.start", async ($, e, next) => {
  on("command.run", { command: "replay" }, async ($, e) => {
  on("tool.call", async ($, e, next) => {
  on("turn.start", ($, e, next) => {
  on("turn.complete", async ($, e, next) => {
  on("ui.render", { component: "AbovePrompt" }, ($, e, next) => {
  on("ui.render", { component: "Pane" }, ($, e, next) => {
  on("ui.close", ($, e, next) => {
