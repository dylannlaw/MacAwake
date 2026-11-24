# Contributing to MacAwake

Thanks for wanting to help. MacAwake is a small app on purpose, so please open an issue to talk about
a new feature before you build it.

## How changes get in

`main` is protected. Nobody can push to it directly; every change arrives as a pull request, and only
the maintainer (@dylannlaw) can approve and merge it.

1. **Fork** the repository and create a branch in your fork (for example `fix/timer-label`).
2. **Follow [AGENTS.md](AGENTS.md).** It's the project's working agreement for humans and AI agents:
   read the change notes in `docs/`, build with `./build.sh`, check your change in the app, update
   `README.md` / `TECHNICAL.md`, and add a change note in `docs/changes/`.
3. **Open a pull request** against `main` and fill in the checklist.
4. **Wait for the build.** For first-time contributors, the maintainer approves the build to run.
   The build must pass.
5. **Review.** The maintainer reviews, may ask for changes, and merges with a squash merge.

Every merge to `main` publishes a new release, so main must always be releasable.

## Ground rules

- Keep it small: no new dependencies.
- Anything that runs as root (`Helper/`) must treat its input as untrusted.
- Never cancel or change power events that MacAwake didn't create.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.
- Be kind. Reviews are about the code, not the person.
