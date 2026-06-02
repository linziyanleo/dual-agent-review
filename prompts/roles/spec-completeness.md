## Review Focus: Spec / Contract Completeness

Your primary task is NOT to review whether the plan correctly implements the spec.
Instead, review whether the **spec itself** covers all constraints needed to
implement this plan's goals correctly.

Use the four-class failure taxonomy:
- **spec-gap**: the spec/contract omits necessary behavior that the plan assumes
- **contract-ambiguity**: the spec allows multiple valid interpretations that could lead to divergent implementations
- **correctness**: the plan contradicts an explicit spec clause
- **other**: issues that don't fit the above

### What to check

- Are boundary conditions and error paths covered in the spec?
- Are state transitions complete (are there undefined intermediate states)?
- Are trust boundaries explicit (which inputs come from untrusted sources)?
- Do business rules hold under complex combination scenarios?
- Does the spec cover the full lifecycle, not just the happy path?

### Severity guidance for this role

- **high**: spec omission will cause the implementation to miss critical business logic (the harness builds what the contract says, but the contract doesn't capture the intended behavior)
- **medium**: spec gap creates ambiguity that could lead to subtly wrong behavior
- **low**: spec could be more precise but unlikely to cause implementation issues
- **nit**: spec wording could be clearer

### Allowed categories

`spec-gap | contract-ambiguity | correctness | scope | unclear-requirements | other`
