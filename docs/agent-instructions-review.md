# Agent instruction review — 14 September 2026

Reviewed against OpenAI's [Rethinking skills and prompts for GPT-6 Astra](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra) and its [prompting guidance](https://developers.openai.com/api/docs/guides/latest-model/gpt-6-astra.md#prompting-best-practices).

## Applied to this project

There was no repository-local `AGENTS.md`, `AGENTS.override.md`, `CLAUDE.md`, or `SKILL.md` in the inspected project tree. The engineering instructions supplied in the conversation were already concise; they are preserved in the new root `AGENTS.md`.

The added guidance addresses this project's actual workflow:

- Route to architecture, iOS setup, or analysis documentation only when relevant.
- Finish the requested behavior and address change-related failures before handing it back; distinguish implementation, physical-device testing, and installation.
- Select verification by risk. Repeated broad device runs after small unrelated edits are not a default requirement.
- Separate disposable fixtures from the user's existing phone project. The latter needs non-saving checks and serial device sessions, not a blanket assumption that all tests are isolated.
- Make local delegation optional and task-specific rather than prescribing an explorer/worker/tester/reviewer sequence for every multi-file change.

No app code, model defaults, installed skills, or global settings were changed. No new skill was added because these are repository-wide working preferences, not a separate reusable workflow.

## Global findings outside this change

The session's available-skill catalog contains repeated names, including HyperFrames skills and React best-practices skills, plus several overlapping UI/design entries. Repository instructions cannot remove that catalog overhead.

The inspected global `astra-orchestrator/SKILL.md` has broad mandatory-delegation triggers, including repository exploration, multiple files, and external fact verification. It also prescribes model roles. Those rules can add overhead to localized work. Its user-instruction precedence allows the explicit project preference to narrow this workflow, subject to session constraints; the global file itself remains unchanged.

A separate global cleanup would need to choose the canonical skill packages, narrow their triggers, and revise the orchestration policy. Avoid adding shadow copies inside this repository: that would increase duplication. The audit does not claim every installed skill was read or validated.

## Verification

Checked the new instruction files and their local document targets. No application tests, device operations, or model-performance evaluation were needed for this documentation-only change. Future work should assess the policy through task outcomes, not assume that shorter instructions alone improve correctness.
