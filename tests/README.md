# Tests

Dependency-free Lua tests for the parts of the plugin that are pure logic. They
run under a plain `luajit` outside KOReader, by stubbing the modules a unit
under test reaches for.

```sh
sh tests/run.sh              # uses `luajit` from PATH
LUA=lua5.1 sh tests/run.sh   # or pick an interpreter
```

Each suite is one file, runs in its own interpreter, and exits non-zero on
failure.

What belongs here: path arithmetic, escaping, hashing, the shape of a request,
control flow that decides what gets sent. What does not: anything that needs a
real socket, a real device, or KOReader's widget tree.
