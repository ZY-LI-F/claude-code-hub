# Review Output Schema

Produce your review in strict markdown format. Each finding on its own line,
prefixed by its severity:

```
BLOCKING: <one-line description> — file:line
  Rationale: <2-3 sentences on why>
  Fix: <concrete suggestion>

IMPORTANT: <one-line description> — file:line
  Rationale: ...
  Fix: ...

NIT: <one-line description> — file:line
```

## Severity definitions

- **BLOCKING** — correctness bugs, security holes, broken tests, missing
  required functionality. Must be fixed before merge.
- **IMPORTANT** — design/architecture concerns, missing test coverage for
  obvious edge cases, poor error handling. Should be fixed this iteration
  or explicitly deferred with reasoning.
- **NIT** — style, naming, micro-optimizations. Can be skipped.

## Required trailer

End your output with exactly one of these lines:

```
VERDICT: APPROVED
```
or
```
VERDICT: NEEDS_CHANGES
```

## Focus by scenario

- **crud** — input validation, error paths, HTTP status codes, DB constraints,
  auth, request/response shape tests.
- **algorithm** — correctness on edge cases (empty/single/max), complexity,
  overflow/precision, property-based test coverage.
- **bugfix** — does the fix actually address the RCA? any regressions?
  is there a regression test that would have caught the original bug?
- **generic** — correctness, tests, security, maintainability.
