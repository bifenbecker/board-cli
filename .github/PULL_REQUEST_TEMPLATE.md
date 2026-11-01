<!--
Headings stay as they are: reviewers, people and automated, find sections by them.
Every comment is removed once its section is written. An optional section with nothing to say is
removed whole; a required one with nothing to say reads "None".
-->

## Context

<!--
Required. The ticket first, as a link — or "No ticket — <why>".
Then two or three sentences: the problem, and why it is solved this way. Up to 60 words.
When the two need more room, split them into "### Problem" and "### Solution".
-->

## Changes

<!--
Required. What behaves differently now, one line each, grouped by behaviour — not by file:
the diff lists the files.

When the domain model changes, a table of it — required then:

| Entity | Attribute | Change |
|---|---|---|
| Invitation | `expires_at` | added — when the code stops being accepted |

When the API changes in a way a caller notices — an endpoint, a request or response contract, an
error — a "### Breaking changes" subsection: what breaks, and what a caller does instead.
-->

## Decisions

<!--
Optional. One line per choice made on purpose: **the choice** — why.
Collected from the Decision footers of the commits.
-->

## How it was checked

<!--
Required. The tests added or changed, what was verified by hand, and what was not verified.
-->

## Review focus

<!--
Required. One to three places where a mistake is most likely or would cost most, and why.
-->

## Migration and rollback

<!--
Optional. When the schema or the settings change: what a deploy needs, and whether reverting
this request is safe.
-->

## Out of scope

<!--
Optional. What a reader would expect here and is deliberately left out, with its follow-up.
-->
