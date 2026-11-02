# Background compaction and stable turns

Each retained history owns a durable transcript and binary summary tree.
Workers build summaries in the background. Each user turn starts with a
complete, bounded history view. Its model calls extend one message chain with
tool calls, results, and accepted
steering. The history prefix stays fixed until that turn ends.

Profiles and retained histories have distinct owners. See the
[Developer guide](../Resources/Help/developer-guide.md) for history selection
and the lifetime of a retired history's compactor.

View watermarks describe the next turn's history view. Crossing a watermark
during tool work does not replace a running turn's context or wait for
background summaries.

Workers can persist immutable summary nodes while a turn runs. The view defers
coarsening until after `turn_end`, while raw transcript writes remain durable.
The next turn waits for the complete compacted history before its first model
call. This preserves exact history through zoom and keeps incomplete summaries
out of the next prompt.

An independent summary transport owns its cancellation and streaming state.
The pool bounds summary requests by the configured worker count. Across serving
engines, the application avoids unnecessary prefix changes, repeated canceled
summary requests, and unbounded background fan-out. These are application design
requirements regardless of a server's cache policy.

## Design evidence

[Victor Taelin's UniiChat design](https://gist.github.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449)
specifies background summary construction, batched view merges, and a summary
wait before a new turn. Goblin captures its history before the tool loop and
publishes view coarsening after `turn_end`.

[Don't Break the Cache](https://arxiv.org/abs/2601.06007), revised January 2026,
evaluates prompt caching in long agent workflows. It finds that placement of
dynamic content and provider-specific cache strategy affect cost and latency.
The application-level consequence here is to preserve the existing prefix and
append new results, rather than rebuilding the history during a turn.

[KVFlow](https://arxiv.org/abs/2507.07400) studies workflow-aware retention and
overlapped prefetching for agent caches. It supports treating future reuse as
a scheduling concern. It does not establish that more concurrent summary
requests improve this deployment.

[PrefixBench-H100](https://arxiv.org/abs/2609.19657), September 2026, measures
prefix reuse across concurrency, cache configuration, and memory pressure.
Its engine-specific results do not change the application's requirement to
avoid avoidable cache churn. Server eviction measurements are not an acceptance
gate for preserving stable prefixes and bounded asynchronous work.

The regression test stalls background summaries during a long tool turn,
verifies that the turn finishes with its prefix and results intact, then
verifies that the next prompt waits for a complete compacted view. Live native
acceptance remains separate from this deterministic engine evidence.
