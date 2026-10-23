# User preferences

Durable preferences and corrections stated by the user. Maintained by the `ino` Worker; included in every Worker Contract.

## Planning & plan format

- Follow the target repo's documented conventions for plan artifacts (research.md, big-picture.md, detailed-plan.md); use shikamaru default `docs/plans/YYYY-MM-DD-<slug>/` only when the repo has no rule. (2026-10-01)
- When requirements questions remain unanswered, proceed with shikamaru's recommended options and state them in the plan; do not re-ask. (2026-10-01)

## Requirements I always have

## Workflow & tooling

- Never push a branch without self-review first. For PRs: create as draft, run local self-review, fix findings, then mark ready to avoid re-running the full CI suite on each fix. For a stack of PR branches, self-review and open only the bottom branch; never self-review several stack branches at once. After it merges, rebase the rest onto main and repeat for the next branch. Once the human approves a stack, merge each PR (rebase merge) as soon as it is mergeable (required checks green including the code-review verdict after /review, every review thread resolved), then continue to the next branch without asking again. (2026-10-22)
- When acting as shikamaru planner, write the plan and hand execution to other agents (kakashi implementers); do not execute the work. (2026-10-01)
- Keep each PR's unified diff under 240,000 characters; split larger work across multiple PRs before opening. (2026-10-02)
- Group related changes together before running expensive operations (re-embedding, re-indexing, etc.) to batch the work and reduce cost. (2026-10-08)

## Never do
