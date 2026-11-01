---
name: review-changes
description: >-
  Review branch changes. Checks the diff against the base branch using the project's own
  documentation, filters out what it cannot back up, and reports findings to chat and to a file.
argument-hint: "[--depth shallow|deep] [git range] [--out <findings file>]"
allowed-tools: Bash, Read, Grep, Glob, Task, Agent, Write
---

Review of branch changes. Uses only git, the project's documentation and its workflow configuration.
Strictly follow the project's documentation, reached through the root `CLAUDE.md`: the git rules,
the workflow rules and the rest of the documentation index.

IMPORTANT: Reach the git platform only through the project's git platform tool, the one the root
`CLAUDE.md` names.

## Step 1. Depth, range and output file

Every parameter is optional:

Read the flags first and take their values with them; the range is whatever argument is left. It
is not "the first argument that does not start with `--`" — `--depth shallow --out f.json a..b`
would make the range `shallow`, and a review of a range that does not exist reports nothing and
looks like a clean bill of health.

```
depth=<value of --depth, else deep>
out=<value of --out, if given>
range=<the argument that is neither a flag nor the value of one, if any>
[ -n "$range" ] || range="origin/$(sh scripts/workflow.sh get git.default_branch)...HEAD"
branch=$(git branch --show-current)
: "${out:=.tmp/review/$(printf %s "$branch" | tr / -)-$(git rev-parse --short HEAD).json}"
mkdir -p "$(dirname "$out")"
```

Then read the change with `git`: the diff of the range, and the author's recorded decisions —
the `Decision` footers of its commits. Every pass gets them, see step 4.

Empty diff — say so and stop, there is nothing to review.

## Step 2. The review scheme

**Who reviews and against what is the project's decision, not this skill's.** The scheme is the
document about reviewing changes — find it through the documentation index, the root `CLAUDE.md` rather than by scanning files.

No such document — stop and say so. Reviewing against rules the project never wrote down produces
findings nobody agreed to.

Then read the documents it points at, the sections the diff falls under.

## Step 3. The configuration

Everything that is a number or a model name is configuration, not documentation:
`sh scripts/workflow.sh get <key> [default]`, under `review`, with the depth's own values
overriding the shared ones and a role's own values overriding the depth's. A role the scheme names and the configuration does not has nothing to
run on — say so rather than choosing a model.

## Step 4. Review

The shallow depth is one pass, done here, spawning nothing: being quick is the point of it. Its
subject is what the mechanical checks cannot reach, as the scheme states it. The deep depth is the
roles, below.

At either depth the reading is adversarial, as the scheme puts it: what would have to be true for
this change to be wrong, and is it. Carried into every pass below, and it stops where the scheme
stops it — at evidence.

### Roles running in parallel

**First decide which roles apply.** Hold each role's applicability from the scheme against the
list of changed files from step 1, and do not launch the ones it does not reach. A role that
starts up only to read its documents and conclude "not my area" costs as much as one that
reviews — the answer was already visible in the file list.

Every role that was skipped is named in the report, with the reason. A silent skip is the
dangerous kind: too narrow a line in the scheme would quietly switch a check off while the
review still looks complete.

The rest run **as a single batch** so they work concurrently — this is the main source of speed.
Every role is read-only: changing code inside this skill is not allowed.

Each agent gets, and nothing beyond it:

- the range and the diff it should look at;
- its area of responsibility, worded as the scheme words it;
- the paths to its own documents, and what was already read out of them;
- the author's recorded decisions from step 1;
- for the team lead, the other open requests to the same target
- its finding budget;
- the output format below.

Run the agent on the model configured for that role.

### What a pass returns

One block per finding:

```
FILE: <path relative to the repository root>
LINE: <line number in the new version of the file>
LINE_END: <last line if the finding spans several; omit otherwise>
SEVERITY: blocking | minor
CONFIDENCE: <0-100>
ISSUE: <the problem in at most ten words>
DETAIL: <at most two sentences: what goes wrong, and what to do>
REASONING: <only when DETAIL cannot carry the proof — an interleaving, a reproduction; omit otherwise>
FIX: <only when the fix is concrete — a unified diff against the new version; omit otherwise>
SOURCE: <the documented rule or the fact that backs it>
```

`FIX` is given only when the change is one you can stand behind as written. A fix that depends on a
decision — which layer, whether the behaviour is wanted — is described in `DETAIL`, not guessed as a
diff.

The reader sees `ISSUE` as a heading and `DETAIL` under it; `REASONING` is folded away. So
`DETAIL` is what a busy author reads and must be enough to act on: no restating the line the
finding is pinned to, no retelling what the code does, no history of earlier rounds.

`SEVERITY` and `CONFIDENCE` are different axes and must not be conflated: severity answers
"how much does it matter if true", confidence answers "how true is it at all". Filtering goes
by the second, ordering in the report by the first.

`LINE` is the line number **in the new version of the file**: comments are later anchored to
the diff by it, and old-version numbering will not line up.

There is deliberately no third severity: anything that does not reach `minor` is not raised at
all. Otherwise small stuff eats the budget and drowns what actually matters.

### Limits, mandatory at either depth

- **Stay inside the configured budget.** Found more — keep the most important ones, drop the
  rest silently.
- **Silence by default.** In doubt — say nothing. A review that found nothing is a normal
  outcome, not a sign of poor work. The rule is about doubt, not about restraint: something
  you went and verified is reported, however plainly the diff states the opposite in a comment.
- **Do not flag what is caught mechanically.** The scheme lists what the project checks by
  itself — linters, type checkers, architecture contracts, tests. Those checks go red on their
  own; a comment repeating them costs the reader attention and changes nothing.
- **Touched lines only.** A problem that predates these changes is not a finding.
- **A recorded decision is not a finding.** Where the author wrote down why something is the way
  it is, a different preference about the same choice is not raised. What still is: a defect the
  decision did not account for — lost data, a race, a hole — raised with the decision named.

## Step 5. Filtering

In a single pass — do not spawn an agent per finding, that is slower and no more accurate.
Collect the findings, merge duplicates (two roles often see the same thing: keep the one whose
wording is sharper) and apply the filters in order:

1. **By confidence:** keep only what reaches the configured minimum. The scale: 0 — false
   positive, or a problem that predates the changes; 25 — might be real, could not verify; 50 —
   real but minor next to the rest of the diff; 75 — verified, likely to bite in practice, or
   directly violates a documented rule; 100 — confirmed by evidence.
2. **By proportion:** no more than roughly one finding per the configured number of diff lines.
   More than that means the pass is nitpicking: keep the heaviest ones. Count the lines actually
   reviewed: generated files and long prose carried along by the diff inflate the count and
   would silently squeeze out findings about the code.

Typical false positives dropped by the first filter: a nitpick a senior would not raise;
anything a linter, type checker or the tests would catch; a behaviour change that is the very
point of the work; lines the author did not touch.

## Step 6. Deliver the result

Two outputs: a file for programs, text for a human.

**File** — the path from step 1. This is the contract with the caller; when its shape changes,
bump `schema_version` so consumers fail loudly instead of breaking silently:

```json
{
  "schema_version": 2,
  "depth": "shallow | deep",
  "branch": "<branch under review>",
  "range": { "from": "<sha>", "to": "<sha>" },
  "head_sha": "<full sha>",
  "stats": { "files": 12, "added": 240, "deleted": 35 },
  "filtered_out": 2,
  "findings": [
    {
      "path": "<path relative to the repository root>",
      "line": 42,
      "line_end": null,
      "severity": "blocking",
      "confidence": 90,
      "role": "<the role that found it, null at the shallow depth>",
      "issue": "<the problem in at most ten words>",
      "detail": "<at most two sentences: what goes wrong, and what to do>",
      "reasoning": null,
      "fix": null,
      "source": "<the documented rule or the fact that backs it>"
    }
  ]
}
```

- `depth` — which pass wrote the file: a caller that asked for one and got the other should be
  able to tell.
- `range.from` and `range.to` are sha-resolved ends of the range rather than one string: the
  consumer needs exactly those and should not have to parse `a...b`.
- `head_sha` — full, for permanent links to code.
- `line_end` — `null` when the finding is on a single line.
- `reasoning` and `fix` — `null` unless the pass returned them.
- `role` — who found it; without it there is no way to see which role is noisy and nothing to
  tune.
- `findings` are sorted: `blocking` first, then by descending `confidence`.
- No findings — the array is empty, the file is still written. A caller decides by reading it,
  and a missing file is indistinguishable from a pass that died.

Field values in the file are written in English, same as this document.

**To chat** — a short report in the review language from the workflow configuration: the depth, how many
findings and of what severity, one line each (`path:line` — the gist), how many were filtered out,
which roles were skipped and why, which range was reviewed and the path to the file. If there are
no findings, say so plainly: that is a normal outcome. Do not retell the file's contents.
