# Runtime verification contracts

Each Goblin profile owns one continuing session. Runtime changes preserve its active
turn, accepted input, saved history, and explicit lifecycle boundaries.

The [Developer guide](../Resources/Help/developer-guide.md) describes native
profile ownership and independent history, core, and autonomy setup changes.

## History admission and active turns

A new turn waits only for the complete bounded history prefix it needs.
An input row outside that prefix cannot block its own admission.

During the active tool loop, model calls retain the captured instruction and
history prefix. Tool results and accepted steering append to that chain.
A blocked background summarizer does not pause the running turn or force a
context replacement. View coarsening is published between turns.

Exercise this boundary with `test_context_compaction.py` and
`test_view_recovery.py`.

## Worker ownership

A worker receives a detached parent context snapshot and explicit zoom access.
Automatic reports and explicit waits claim one report queue, so each report is
delivered once. Cancellation remains authoritative through admission and a
worker's outcome represents interruption accurately.

Exercise this boundary with `test_worker_lifecycle.py` and `test_session.py`.

## Stream ownership

A transport may retry before visible response output begins. Once text,
reasoning, or tool output has started, retain that attempt's partial output and
failure instead of concatenating a replacement response.

Exercise this boundary with `test_stream_retry.py`.

## Bounded history and responsive control

The raw log uses an offset index and a byte-bounded decoded cache. Ordinary
runtime snapshots carry bounded state. Earlier messages, full saved records,
and saved Gist use separate paged reads.

Disk reads, decoding, cloning, and sizing do not hold the control-path mutex.
Stop and snapshots remain serviceable during slow history reads.

Exercise these boundaries with `test_log_storage.py`, `test_history_pages.py`,
and `test_history_control_lane.py`, plus native history and intake tests.

## Independent summary scheduling

Ready source leaves can proceed while another summary is unavailable. Parent
nodes retain their true built-child dependencies. Each request captures a
complete context prefix, and summary concurrency remains bounded.

Exercise this boundary with `test_compactor_independence.py`,
`test_compactor_latency.py`, and `test_context_compaction.py`.

## Reconnect and cancellation

Native connection generations reject stale callbacks. Disconnection settles
controls while preserving accepted input and visible partial output. Reconnect
cleans up its failed owned child, reloads saved rows, and reconciles pending
native rows without replaying accepted work.

Exercise native connection, intake, conversation, and recovery tests. Include
the packaged-engine startup and reopen fixture against the built app.

## Operating baseline and packaged assets

Each root and worker turn receives the full declared pstack operating core and
complete effective catalog. Active-turn instructions remain unchanged when a
skill file changes. The next turn receives the update.

The package manifest names every required governing skill. Missing declared
assets fail package validation. Summary requests preserve their source-only
role and do not repeat the baseline into conversation summaries.

Exercise `test_instruction_baseline.py` and `test_release_build.py` against
actual request construction and copied package assets.

## Native acceptance

After focused checks, build a separate replacement bundle. Verify its source
identity and signature. Exercise the changed native path with a fresh app home
and the relevant existing-data fixture.

For installed acceptance, preserve current work and choose an idle update
boundary. Verify the effective configuration, earlier-history reads, saved
record details, cancellation, and reconnect as relevant to the change. Keep
real account and hardware results distinct from isolated test evidence.
