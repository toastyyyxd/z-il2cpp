# AGENTS

## Commit messages

Terse.
One line.
No body.
The change explains itself.

## Writing

Comments and documentation must be simple to understand.
Write full words.
No contractions.
No symbols in place of words.
One clause per sentence.
No chained clauses.
No narrative.
No anthropomorphic wording.
No backstory.

## Comments

Add a comment only when the content is not clear without it.
Explain the immediate content.
Do not restate code.
No file headers.
No meta docs.

## Documentation

README is the only document.
Content: structure, ABI, commands.

## Before commit

Run `zig build test`.
Run `zig build fmt`.
Run `scripts/smoke.sh` when the hot module or artifacts change.
