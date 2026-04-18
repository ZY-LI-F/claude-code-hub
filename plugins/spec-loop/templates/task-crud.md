# Task: <name>

**Scenario**: crud
**Outer iter**: <N> / **Inner iter**: <M>

## Goal
<One paragraph: what this task delivers and why it matters for the spec.>

## Interface contract

### Endpoints (or components)
For each endpoint/component:
- **Method + Path** (or **Component name + props**)
- **Request shape** (body / params / query)
- **Response shape** (success and error)
- **Auth requirement** (none / authenticated / role:X)

### Data model changes
- Tables/collections affected: ...
- Migration needed? yes/no; if yes, describe.

## Acceptance criteria
- [ ] <behavioral criterion 1, e.g. "GET /users/:id returns 200 and JSON {id,name,email} for existing user">
- [ ] <behavioral criterion 2, e.g. "GET /users/:id returns 404 for missing user">
- [ ] <error path criterion, e.g. "POST /users returns 400 with field errors on invalid body">

## Tests to write
Specify file paths and test names:
- `tests/users.test.js`:
  - `GET /users/:id returns user when found`
  - `GET /users/:id returns 404 when not found`
  - `POST /users validates email format`

## Existing patterns to follow
Point Codex at reference code:
- Route pattern: `src/routes/<existing-route>.js`
- Validation style: `src/middleware/validate.js`
- Error handling: `src/lib/errors.js`

## Out of scope
- Explicitly list what this task will NOT do. Prevents scope creep.

## Success checklist (for review)
- [ ] All endpoints return documented shapes
- [ ] All error paths return correct HTTP codes
- [ ] Tests cover happy path + at least one error per endpoint
- [ ] No hardcoded secrets
- [ ] Input validation on all user-supplied data
