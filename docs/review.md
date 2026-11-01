# Review

Who checks what, against which document.

Review split into roles. Each role works alone, in own area, from own documents. Without split,
pass collapses into one general reading judged by feel.

Read change adversarially: not "does it look right" but "what must be true for it to be wrong".
Findings come from there. Stop at evidence: suspicion not shown is not finding.

## Depths

Two depths. Different things, not one reading done twice.

### Shallow

One quick pass, no roles. Subject: what shellcheck and `just lint` cannot reach. Change tested at
all, styleguide where judgement needed, naming of files and functions, help text, docs, typos,
slips.

Not its subject: structure, anything needing whole change held in mind.

Threshold higher than deep: speaks to someone finishing, so speaks only when sure. Findings printed,
never published. Blocking finding stops work going further; rest is advice, author decides.

### Deep

Full review: every role whose area change reaches, each from own documents, normal threshold.

Runs as loop, not single verdict: review, fixes, review again over what fixes changed, until nothing
blocking left. Round count and when loop narrows to blocking only: workflow configuration.

Round: read where review stands, review what is new, answer what came back, leave fixes behind.
Fixes carry loop: their change starts next round. Loop ends by itself when round leaves nothing
behind. Also ends when open item needs decision review cannot take, and ends outright when request
used all allowed rounds.

Every ending left on request itself, not only in output of whatever ran round. Next is person
picking request up; they must see which ending it was.

## Roles

Roles are deep review; shallow has none.

| Role      | Area                                                                   | Applies to                                       | Documents                      |
| --------- | ---------------------------------------------------------------------- | ------------------------------------------------ | ------------------------------ |
| Engineer  | Style and bugs                                                         | Shell code: `bin/`, `lib/`, `scripts/`, `install.sh` | [styleguide.md](styleguide.md) |
| Team lead | Light pass over whole change, and how it sits with other open requests | Always                                           | [git-flow.md](git-flow.md)     |

This document says what role is for. Numbers and names to tune (model, finding budget, threshold)
live in workflow configuration, per role and per depth. Model follows judgement role needs: light
pass needs no large model, reading code does. Review runs every round, so role cost matters.

Applicability answers: does role have work on this change? Role with nothing to do not started:
learning "not my area" from inside role pays for answer visible in changed-file list.

Skip must be visible. Role not started named in report with reason. Otherwise narrow rule silently
switches check off while review still looks complete.

### Engineer

Two jobs.

First: styleguide as written. Where no rule, job does not apply; inventing rule is not role's call.

Second: bugs in any executable code. Wrong logic, runtime failure, unhandled failure, untaken
branch, edge case, exit code that lies, bash-only construct in POSIX sh, GitHub and GitLab variants
of one command disagreeing on JSON shape.

### Team lead

Light pass, no deep dives. Obvious mistakes. Git history: commits meaningful, follow project format,
branch not carrying what it should not. How change presented. Small organisational matters.

Other requests open at same time: study each (code, tests, description), check their decisions do
not contradict this one's.

## Not covered by review

What project checks automatically: shellcheck, help completeness and the provider contract (`just lint`), tests (`just test`), CI. Repeating them
as comment costs twice: reader attention spent on thing about to be fixed anyway, real findings
drown in list.
