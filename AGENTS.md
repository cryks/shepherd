# Shepherd

## Changelog Policy

Update CHANGELOG.md in the same commit as any change users can see.
Writing the entry while the change is fresh keeps it more accurate than
reconstructing it from git log later.

- Collect unreleased entries under `## Unreleased`. A release turns that
  heading into a version and a date.
- Categories are Added / Changed / Fixed. Match the wording of the
  existing sections.
- One sentence per entry, saying what changed. Reasoning, mechanism, and
  implementation history belong in the commit message body.
- Cut what the reader can see for themselves: which control to drag,
  which parts of the screen changed, what the feature obviously implies.
- Leave out internal refactors, tests, CI, and documentation-only changes.
