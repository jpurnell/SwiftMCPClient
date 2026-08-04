# Migration Report — SwiftMCPClient

Migrated to the v2 layout on 2026-08-04.

- Files in the pre-migration tree: 49
- Project documents repatriated to `project/`: 4
- Pre-migration tree preserved at: `development-guidelines.pre-v2/` (gitignored)
- Framework files untracked from the index: 0
- Master plan: **filled**

## Framework divergence

Content found locally that upstream does not ship. **Nothing was discarded** — it
remains in `development-guidelines.pre-v2/`. Each item is an upstream candidate.

### Local-only rules
_none_

### Locally modified rules
Content upstream has never held — genuine local edits.

_none_

### Stale rules (no action needed)
Older upstream releases, superseded by the framework just installed. Listed for
completeness only — nothing to upstream.

- `DEVELOPMENT_WORKFLOW_TUTORIAL.md`
- `settings.json`
- `settings.local.json`
- `swift-development.md`
- `SKILL.md`
- `SKILL.md`
- `SKILL.md`
- `SKILL.md`
- `03_DOCC_GUIDELINES.md`
- `08_FLOATING_POINT_FORMATTING.md`
- `09_TEST_DRIVEN_DEVELOPMENT.md`
- `RELEASE_CHECKLIST.md`
- `05_DESIGN_PROPOSAL.md`
- `PERFORMANCE.md`
- `06_ARCHITECTURE_DECISIONS.md`
- `01_CODING_RULES.md`
- `11_NO_HARDCODED_CONSTANTS.md`
- `10_APPLICATION_TESTING_PATTERNS.md`
- `07_SESSION_WORKFLOW.md`
- `setup.swift`

## Next steps

1. Review `project/` and commit it to this repository.
2. Upstream anything listed above that belongs in the framework.
3. Only then remove `development-guidelines.pre-v2/`.
4. The `project-state/*` branch on the development-guidelines remote may be
   deleted only after this repository's commit is pushed.
