# Decisions (append-only)

Each entry: date, context, options considered, choice, reasoning. Never edit past entries; supersede them with a new entry.

---

## D-001 (2026-10-05) Remove the commented-out `node.js.yml` workflow

- Context: `.github/workflows/node.js.yml` is entirely commented out. GitHub treats it as an invalid workflow and reports a failed run on every push, which pollutes CI status for this branch.
- Options: (a) leave it, (b) delete it, (c) rewrite it as the macOS CI workflow.
- Choice: (b) delete now; the macOS CI workflow is added separately as `macos-ci.yml` in phase 3.
- Reasoning: upstream Windows CI is not preserved in this fork, and a red run on every push hides real failures.

## D-002 (2026-10-05) Fixture-to-scenario mapping source

- Context: `tests/fixtures/combatlogs/README.md` says only "Combat log file name is the description of the file." The files are byte-identical to upstream's `tests/logs/`, and upstream's `tests/src/<flavour>/<name>.py` integration definitions state the expected outcome (record or not, expected file name) for each log.
- Choice: use the file names plus the upstream `.py` definitions as the scenario map. Unit tests use small excerpts extracted to `tests/fixtures/excerpts/`; full files back an optional slower integration test.
- Reasoning: the `.py` files are the upstream author's ground truth for these exact logs, which is stronger than inferring from names.

## D-003 (2026-10-05) Quality gates start from a red baseline

- Context: at fork time `tsc --noEmit` reports 55 errors (mostly library typings and missing `release/app` modules), ESLint reports 52 errors (mostly `no-explicit-any` and react-hooks v7 compiler rules in renderer code), and all 7 jest suites fail to load (Electron import, `baseUrl` paths not mapped in jest). Webpack builds with `transpileOnly`, so upstream never type-checks.
- Choice: make typecheck, lint, and unit tests real CI gates by fixing configuration (`skipLibCheck`, jest `moduleDirectories` and an Electron stub, vendored `noobs` types) and downgrading the pre-existing renderer-only lint rule categories to warnings rather than rewriting unrelated renderer code.
- Reasoning: gates must be green to be useful, and rewriting renderer code that the port does not touch is out of scope and risky.
