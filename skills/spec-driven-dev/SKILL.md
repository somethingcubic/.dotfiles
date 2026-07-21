---
name: spec-driven-dev
description: >
  Transform raw requirements into structured specs before any code is written.
  Implements Spec-Driven Development (SDD) — the practice of writing a complete,
  verifiable specification as the first deliverable of any feature/task.
  Use when: (1) user describes a feature, task, or requirement to implement,
  (2) user says "write a spec", "spec this out", "SDD", "spec-driven",
  (3) before starting any coding task that involves more than a trivial one-liner fix,
  (4) user asks to plan or scope a piece of work.
  NOT for: bug fixes with obvious single-line solutions, pure refactors with no behavior change,
  or tasks where a spec already exists and user wants to jump to implementation.
---

# Spec-Driven Development (SDD)

## Philosophy

No code without a spec. A spec is a contract between human and AI — it eliminates
"虚心认错从不悔改" by making success criteria explicit and verifiable before
any implementation begins.

## Workflow

1. Receive requirement (however vague)
2. Ask ≤3 clarifying questions (only if genuinely ambiguous — try to infer first)
3. Generate spec using the template below
4. Get human approval on spec
5. Only then proceed to implementation

## Spec Template

```markdown
# [Feature/Task Name]

## Problem
What's broken or missing. Observable symptoms, not guesses.
Include metrics if available (e.g., "API takes 3s, target <200ms").

## Goal
One sentence. What "done" looks like from user's perspective.

## Current State
- Relevant files: `path/to/file.ts` — role
- Existing behavior: what happens now
- Dependencies: what this touches
(Read actual code. Never guess.)

## Acceptance Criteria
Observable behaviors, each directly testable:
- [ ] User can do X and sees Y
- [ ] Edge case Z returns proper error, not 500
- [ ] Performance: completes within N ms/s
- [ ] Existing feature W still works unchanged

## Constraints
Non-negotiable guardrails:
- Don't break existing API contract
- No new dependencies unless justified
- Must have migration files for DB changes
- (project-specific constraints)

## Out of Scope
Explicitly what NOT to do this round:
- Feature A — next iteration
- Refactor B — separate task
- Don't touch file C

## Decisions
Non-obvious choices and their rationale:
- **Why X over Y**: reasoning with evidence
- **Why not Z**: what was considered and rejected

## Implementation Hints (optional)
Only if there's a strong preferred approach. Keep it brief.
Prefer constraints over instructions.
```

## Rules

1. **Problem-first, not solution-first.** Describe what's wrong, not what to build.
   Let the implementation phase find the best solution.

2. **Acceptance criteria = observable behaviors.** Not implementation details.
   "User sees X" not "Use library Y". Each criterion must be verifiable
   without reading source code.

3. **Out of Scope is mandatory.** No spec is complete without explicitly stating
   what NOT to do. This is the #1 defense against AI scope creep.

4. **Read before writing.** Current State must reference actual file paths and
   actual current behavior. `grep`, `read`, `find` — whatever it takes.
   Never write Current State from memory or assumption.

5. **Size it right.** One spec = 1-3 days of work max. If bigger, split into
   multiple specs with clear dependency order.

6. **Decisions are first-class.** Every non-obvious choice gets a decision record.
   Prevents future re-litigation of the same trade-offs.

## Interaction Patterns

### When requirement is clear
Generate spec immediately. Present for approval.

### When requirement is vague
Ask up to 3 targeted questions. Then generate best-effort spec
with `[TBD]` markers for remaining unknowns. Don't block on perfection.

### When multiple specs needed
Output a **Spec Map** first:

```
Spec 1: [name] — [one-line goal] (no deps)
Spec 2: [name] — [one-line goal] (depends on Spec 1)
Spec 3: [name] — [one-line goal] (no deps, parallel with 1-2)
```

Then write each spec individually upon approval.

### After spec approval
Transition to implementation mode. Reference the spec's acceptance criteria
as the checklist. Check off each criterion as it's met.
On completion, run through all criteria one final time to verify.

## Anti-Patterns to Avoid

- ❌ Writing code before spec is approved
- ❌ Acceptance criteria that describe implementation ("use Redis")
- ❌ Missing Out of Scope section
- ❌ Current State written from assumptions instead of actual code
- ❌ Specs larger than 3 days of work
- ❌ Vague criteria ("should work well", "good performance")
