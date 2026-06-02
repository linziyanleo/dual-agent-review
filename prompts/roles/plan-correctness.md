## Review Focus: Plan Correctness

Your primary task is to evaluate whether this plan will produce correct,
secure, and maintainable software when executed as-is.

Cross-check the plan against the Spec Context above — flag deviations from
established project norms.

For each major step, ask "what would make this fail?" before accepting it.
Challenge hidden assumptions explicitly.

### Severity guidance for this role

- **high**: plan will produce broken / insecure / wrong behavior if executed as-is
- **medium**: plan will work but has clear quality/maintainability/scope problems
- **low**: improvement worth doing but not blocking
- **nit**: style / wording / minor — use sparingly, this is not a syntax review

### Allowed categories

`correctness | security | performance | maintainability | scope | testing | unclear-requirements | other`
