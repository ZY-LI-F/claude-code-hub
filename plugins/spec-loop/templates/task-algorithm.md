# Task: <n>

**Scenario**: algorithm
**Outer iter**: <N> / **Inner iter**: <M>

## Goal
<One paragraph: what the algorithm does and why.>

## Function signature
```<language>
// Exact signature including types/annotations
function_name(param1: Type1, param2: Type2) -> ReturnType
```

## Specification

### Inputs
- `param1`: <type, constraints, valid range>
- `param2`: <type, constraints>

### Output
- <type, what it represents, constraints>

### Behavior
Describe the algorithm in 3-5 sentences. Include any formulas or pseudocode that clarifies.

### Complexity target
- Time: O(...)
- Space: O(...)

## Edge cases (must all be handled)
- [ ] Empty input
- [ ] Single-element input
- [ ] Maximum-size input (define what "max" means)
- [ ] Invalid input → how does the function signal error? (throw? return sentinel?)
- [ ] <domain-specific edge case 1>
- [ ] <domain-specific edge case 2>

## Tests to write
File path: `tests/test_<module>.py` (or equivalent)

Required cases:
- Happy path: small representative input
- Each edge case above gets its own test
- At least one large-input test to catch complexity issues
- At least one randomized/property-based test where appropriate

Use table-driven tests where the framework supports it.

## Out of scope
- Performance optimization beyond the stated complexity target
- Integration with other modules (keep the function pure)

## Success checklist (for review)
- [ ] All edge cases have tests
- [ ] Function is pure / has clear side effects documented
- [ ] Complexity meets target (verified by test or reasoning)
- [ ] Error signaling is consistent with project conventions
