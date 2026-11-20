# Brief prompting ideas

These are optional suggestions for writing a brief's `## Firstmate spec`; use them with judgment or ignore them.
Leave `## Captain's intent` in the captain's own words.
They never widen the captain's ask or invent a target, number, or reference that the captain or measured evidence did not supply.

- Measurable target: replace "optimize" with a number, such as "make this 10x faster".
- Measure, then redesign: "measure and redesign for optimal IO, memory, and CPU based on historical data".
- Differential oracle: replace "fix all bugs" with "differentially test this against X and close all gaps".
- Named reference: name a known style or reference implementation, such as "match the API style of X".
- Sweeping pattern change: ask for one change applied everywhere, such as "encode implicit state machines in the type system", "replace sequential async calls with joins", or "add end-to-end observability and measure bottlenecks by component".
- Persistence cue: say the work should continue until the target is met, such as "keep going until every gap is closed".

The principles behind these are persistence, higher levels of abstraction, and domain knowledge packed into a few words.
