# Product contract

## Companion

One full-body character stands beside its chat in one transparent native
window. The chat expands and collapses without replacing the session.
Collapsed mode keeps short replies and a quick-message composer. The
character supports drag positioning, optional hold-to-talk and configurable
animation. Always-on-top is an explicit persistent option in either mode.
Custom avatar imports are normalized into app-owned image storage.

## Runtime ownership

SwiftUI/AppKit own presentation; native audio and WebSockets own media. The
bundle includes its Python runtime and engine. Private pipes carry commands,
events, approvals and results. The app opens no listening socket. External
models and tool services are explicit client connections.

Chat, voice input and Autonomy use the same persistent session, workspace,
gist, tools, approvals, cancellation and embedded AetherMind continuity.
Collapsing the chat preserves enabled work. Quitting closes app-owned work.
PTT release mutes the microphone while preserving playback.

Each active turn extends a fixed prompt prefix. Background summary workers use
independent transports and completed context; coarsened history is published
between turns. Worker handoffs carry explicit parent context and deliver each
report once, with cancellation and completion represented truthfully.

Every session and worker receives the full pstack operating core and complete
effective skill catalog in its stable instruction prefix. Specialized procedures
are selected autonomously from their triggers. The bundled framework supports
fresh installs; trusted project and user overrides take effect between turns.
Optional shelf controls constrain detailed retrieval while the governing core
remains present. User instructions and tool permissions govern workflow defaults.
Summary requests preserve decisions and constraints without executing workflows.

Runtime snapshots carry bounded state. Historical messages, full saved records,
and the saved gist use separate paged reads. Exact transcript records remain
append-only, with indexed access and bounded decoded caching.

Engine disconnection settles controls while preserving accepted input and
visible partial output. Reconnect owns cleanup of the failed child, bootstraps
a fresh generation, and reconciles saved rows without resubmitting input.

## Acceptance

Exercise installed chat and tool execution, collapsed quick send and a short
reply, chat reopening, position and option persistence, custom avatar import,
Autonomy, approvals, Stop, and voice connection/mute/End. Keep live hardware
and account decisions distinct from automated code-path checks.

## Distribution

Build source archives from the reviewed tracked tree. Ship generic defaults,
component notices and source, with no installed data, credentials, private
host values, source-machine paths or development history. A release candidate
is local until its owner explicitly authorizes publication. Use a fresh
repository history for that release candidate.
