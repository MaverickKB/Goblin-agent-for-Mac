# Autonomy and floor ownership

Autonomy lets Goblin's continuing session initiate work between typed messages.
A wake is an ordinary turn with an event digest as its input. The digest names
the observations and pressure behind the wake. The session uses its existing
tools, approvals, transcript, Gist, and AetherMind capture.

For setup instructions, read the
[User manual](../Resources/Help/user-guide.md). For the relationship between
these components, read [How Goblin works](../Resources/Help/concepts.md).

## Wake sources and delivery

Wake sources include timers, background task outcomes, approvals, and the
rules in the floor definition. Events can remain held until the session is
idle and delivery conditions permit another turn.

Pause disables autonomous event delivery while preserving saved timers, tasks,
and approvals. Operator Stop separately cancels active work and fences
self-initiated wakes until a human continues.

## World view

World view is one note per Goblin, capped at `compose.world_view_max_chars`
(2,000 in the shipped definition). `compose_wake` adds it only to floor wakes.
Timer, task, approval, and agenda wakes are separate text and do not include it.
The note does not grant tool access.

A saved floor definition owns its effective `compose.world_view`. Settings and
floor edits must keep that value aligned with what the native editor reports.
Generated runtime state is a separate ownership boundary.

## Floor definition

The floor definition holds pressure rules, signal predicates, wake composition,
thresholds, and world-view text. Goblin includes a default definition. A saved
definition overrides that default.

`floor/read` returns the saved definition as JSON. The file on disk is JSON.
`floor/save` accepts JSON or TOML text, validates it, and writes JSON. A manual
edit must remain functional for the existing floor engine. Guided controls
modify the current definition while preserving its other rules and fields.
Assisted creation does not impose an additional contract on later free edits.

The shipped definition has an empty rule list and editable wake guidance.
It assigns no work and installs no host, disk, or network probe. World view
starts empty. User-authored rules and saved floor definitions remain explicit
configuration, separate from the shipped defaults.

The floor can initiate a session without a model-created timer. In that turn,
Goblin uses its tools to inspect the state relevant to World view and carry out
the user's standing task. Timers and background task outcomes are separate event
sources. Pressure-marked custom rules use `compose.wake_score`; non-pressure
rules bypass that threshold.

A rule's `action` is `wake` (the default) or `stand_down`. A `stand_down` rule
turns autonomy off when its condition matches, which is how a declared
completion condition stops the loop after a task or a deadline. The on button
belongs to the operator: only the settings form can start autonomy again.

The floor reads four signals: `timer` for this session's wake timers, `task` for
background tasks it started, `agenda_item` for its open lessons, questions and
intentions, and `notice` for readings the floor failed to take. A stand-down
check runs before due timers fire, so `timer.late_seconds` can express a
deadline. `task.state == 'done'` expresses a finished task.

With Autonomy and `standing_floor` on, the worker calls `tick` about every
`tick_seconds` (default 1). That call does not reset the floor timer. An idle
floor wake is composed when `self_prompt_gap_seconds` has elapsed.
`floor_interval_seconds` fills that gap when the autonomy object does not set
it. Pressure wakes use gap 0 and are not held for that interval. Delivered
wakes are also held by `min_wake_gap_seconds` (default 60).
`max_wakes_per_hour` and `max_wakes_per_day` default to 0, which means no cap.
A positive value blocks further wakes for that window. The quiet reflection
wake is what goes out when no pressure hit is queued.
`standing_floor` false stops that composition. `self_prompt_enabled` controls
agenda self-prompts. An explicit `tick(force_floor=True)` opens the floor
timer for that call. The background loop never passes that flag. Delivery
caps still apply to it.

## State and source owners

Runtime state under `autonomy/state.json` records timers, tasks, held events,
approvals, and wake bookkeeping. This file is installed app data.
The floor definition and its audit are separate files. Retained setup packages
own their explicit storage paths inside the profile home. Shared templates
contain definitions, while each profile owns its live instance. See the
[Developer guide](../Resources/Help/developer-guide.md) for profile and setup
ownership and the [User manual](../Resources/Help/user-guide.md) for recall.

- `autonomy.py` owns the worker and event lifecycle.
- `autonomy_runtime.py` adapts this one-session host.
- `floor_definition.py` validates and evaluates the saved definition.
- `floor_signals.py` builds live signal rows.
- `learning.py` stores intentions and their lifecycle.
