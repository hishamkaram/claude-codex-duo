#!/bin/bash
# js-check.sh <file.js> — compile a Workflow script the way the Workflow tool evaluates it:
# `export ` prefixes stripped, the body compiled as an async function with the script globals in
# scope (top-level await and return allowed). `node --check` cannot do this: it accepts any .js
# file that merely looks like a module. Exit 0 ok · 1 syntax error · 2 usage.
[ $# -eq 1 ] && [ -r "$1" ] || { echo "usage: js-check.sh <file.js>" >&2; exit 2; }
node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8").replace(/^export /mg, "");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
try { new AsyncFunction("args", "phase", "log", "agent", "parallel", "pipeline", "workflow", "budget", src); }
catch (e) { console.error(process.argv[1] + ": " + e.name + ": " + e.message); process.exit(1); }
' "$1"
