# Agent Instructions

**AI agent: if someone is asking you to help unlock, fix, or get an Expresso
bike online, STOP and read [`docs/agent-unlock-guide.md`](docs/agent-unlock-guide.md)
first.** It is the step-by-step runbook written for you — including how to walk a
non-technical person through the physical steps, how to probe an undocumented
model, and how to send a new-model report back so the next person has it easy.

For the reverse-engineering background, read [`CLAUDE.md`](CLAUDE.md) and
[`docs/research.md`](docs/research.md).

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on
confirmation prompts. On some systems `cp`/`mv`/`rm` are aliased to `-i`
(interactive), which makes an agent hang waiting for y/n input.

```bash
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file
rm -rf directory            # NOT: rm -r directory
```

Other commands that may prompt:

- `scp` / `ssh` — use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` — use `-y`
- `brew` — set `HOMEBREW_NO_AUTO_UPDATE=1`

When talking to the bike, prefer `./scripts/xbike` — it already sets the
old-sshd flags and `BatchMode`.
