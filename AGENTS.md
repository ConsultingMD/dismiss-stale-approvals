# Contributor instructions

## Keep documentation aligned

After a meaningful code or configuration change, review the relevant
documentation. Update it when behavior, responsibilities, interfaces, security
boundaries, tooling usage, development workflows, or operational guidance
change. Documentation alignment is part of completing the change.

If no documentation needs to change, state that clearly in the completion
summary instead of making unnecessary edits.

## Write useful documentation

- Optimize for single-pass comprehension by an engineer with no repository
  context. Define concepts before using them and avoid unexplained jargon.
- State where data originates, which external system owns it, how this action
  reads or writes it, and where trust boundaries lie.
- Describe only the current behavior. Use git history for historical context.
- Explain why repository-specific logic exists, not only what each script does.
- Include a concrete end-to-end flow when documenting runtime behavior.
- Keep the root README at summary depth and link to focused pages under
  `docs/`.
- Link to representative scripts and configuration instead of duplicating
  volatile implementation details or exhaustive inventories.
- Keep diagrams and examples conceptual unless exact syntax is required to use
  the action safely.

## Keep tests aligned

- Run `./tests/run.sh` after behavior changes.
- Add regressions to a focused `tests/test_*.sh` file. The runner discovers
  these files automatically.
- Test externally visible behavior and fail-closed outcomes rather than private
  implementation details.
