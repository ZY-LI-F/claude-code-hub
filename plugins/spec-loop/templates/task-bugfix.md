# Task: <n>

**Scenario**: bugfix
**Outer iter**: <N> / **Inner iter**: <M>

## Bug statement
<Exact user-visible symptom, in one sentence.>

## Reproduction
Steps that reliably trigger the bug:
1. ...
2. ...
3. Expected: ...
4. Actual: ...

## Root cause analysis
<Where the bug is (file:line), what invariant is violated, why the invariant was violated.>

Confidence: high / medium / low
If medium or low, document what additional evidence would raise confidence.

## Fix plan
**Minimality principle**: change as few lines as possible. Avoid drive-by refactors.

- Files to modify: <list>
- Lines to change: <approximate count>
- Approach: <1-2 sentences>
- Why this fix addresses the RCA: <explicit link>

## Regression test
**Required**: add a test that would have caught the original bug.

- Test file: <path>
- Test name: <descriptive>
- What it asserts: ...
- Verify: without the fix, this test fails. With the fix, it passes.

## Non-goals
- Do NOT fix unrelated issues you notice.
- Do NOT refactor surrounding code unless it's necessary for the fix.
- Do NOT change public API unless the API itself is the bug.

## Risk assessment
- What could this fix break? <list areas>
- Which existing tests should especially keep passing? <list>

## Success checklist (for review)
- [ ] Regression test fails without the fix, passes with it
- [ ] All previously-passing tests still pass
- [ ] Fix is minimal (reviewable in one screen)
- [ ] RCA actually explains the observed behavior
- [ ] No new unrelated changes smuggled in
