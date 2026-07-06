Default to `APPROVE`. Each failed review creates another fix+review loop, so only block when the issue is truly ship-stopping.

Use `REQUEST_CHANGES` only for blocking issues such as:
- Broken correctness or logic
- Security or permission problems
- Data loss or state corruption risk
- Broken user flow or incomplete required behavior
- Likely regressions in changed paths
- Missing validation or tests for risky code where the change cannot be trusted without them

Keep `APPROVE` and include comments when findings are advisory, such as:
- Documentation drift
- Minor cleanup or maintainability improvements
- Style or preference nits
- Nice-to-have tests on otherwise low-risk changes
