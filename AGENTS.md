# Goblin development

Goblin is a native macOS companion with one persistent agent session per Goblin
profile. SwiftUI and AppKit own presentation. The app retains a private bundled
Python engine for each loaded profile and talks to it through stdin/stdout
pipes. AetherMind is an embedded library.

The application root owns the profile catalog and reusable autonomy template
definitions. Product credential services and account grants remain app-wide.
Each profile owns configuration, avatar and preferences, histories, default
memory core, custom skill shelf, and live autonomy execution. Share an existing
core only through an explicit local or remote connection. Recalling a profile
in a window preserves the outgoing engine and work; an already presented
profile uses its existing window.

Keep history rotation, core creation, and autonomy reset independent. Retain
outgoing data and permit recall. Templates share behavior, World View, full
floor, and schedule definitions; each profile owns its own timer identities,
queued wakes, tasks, learning, and outputs. Returning restores that instance.
Jobs and approvals finish before history or autonomy setup switches. Preserve
operator Stop across setup binding changes, reconstruct store owners, and bind
tool closures to the replacement. Window recall does not stop outgoing work.

Keep application identity, provider defaults and packaging metadata in
product.json. Derive writable locations from the current user's application
support directory. Keep user settings, custom avatars, credentials, session
data and caches out of source and release archives.

Treat other applications, checkouts, running processes and credential stores
as separate owned boundaries. Borrowed source does not authorize operating
its original application. Use independent authentication for this app.

Write readable loops and named intermediates. Preserve component licenses.
Run focused checks for changed behavior, then verify the installed native
journey. Respect Reduce Motion. Give primary actions accessibility identifiers.

Keep each active turn's prompt prefix fixed. Append tool results and accepted
steering to that chain. Build Gist summaries asynchronously on independently
owned transports; publish view coarsening after the turn ends. Wait for complete,
bounded history only before the next turn's first inference. View watermarks
must never pause an active tool loop or replace its context. Verify this with
a blocked summarizer, an unchanged request prefix, and next-turn admission.
Preserve active work when building or installing a repair.

Deliver the complete pstack operating core and effective skill catalog as
governing instructions for every root and worker turn. Keep them outside
ordinary conversation history. Goblin selects specialized procedures from
their triggers without requiring user activation. Capture instructions at
turn admission and retain their exact bytes throughout the active tool chain.
Optional shelf controls constrain retrieval; the bundled governing core remains
present. User instructions, tool permissions and concurrency limits govern
workflow defaults. Summary requests preserve the core while explicitly selecting
faithful summarization. Verify fresh installs, restart, workers and next-turn
refresh against actual serialized requests.

Use expected formats to guide assisted Personality, World view and Floor
creation. Keep the results freely editable by the user and Goblin. Assisted
creation contracts belong to that flow; manual edits use the existing functional
parsers and validation. Preserve original memory cores during import and any
supported adaptation. Report unsupported formats without guessing conversions.

Bootstrap default app-owned cores with generic, useful product knowledge and
quality lessons before their first inheritance read. Seeds contain no private
user information or imposed personality and do not override user instructions.
Preserve existing learning and customized skills. Keep provenance distinct from
authority through tool data, summaries, workers and memory. Expose existing
access controls without changing Ask when needed or Unleashed authority, adding automatic
lockdowns, or introducing sandbox requirements. Propose additional security
changes to the owner before implementation.

Explicit seeded-core creation adds foundations to a separate store. Explicit
empty-core creation retains clean memory until subsequent learning. Neither
operation rewrites the skill shelf or activates its draft connection before a
settings save.

Keep artwork corrections local to the requested defect. Preserve existing prop
geometry and composition; fit a new held tool to the existing prop. Use the
original approved artwork as the reference when a generated draft distorts it.

Release defaults belong to Goblin's product, not an installed profile. Keep
World view empty and monitoring jobs user-assigned. Do not add automatic host
sampling or external judgment backends by adapting another harness. Native
computer use sends observations to the selected agent through its registered
tools. Application code and seed content are Goblin property; third-party
component licenses stay in Runtime/THIRD_PARTY_LICENSES and
Runtime/AETHERMIND_LICENSE.
Only the operator's settings form opens the autonomy switch. A floor rule with
`action: stand_down` may close it when its condition matches, and nothing else
may open it.
`test_product_defaults.py` and `test_floor_defaults.py` verify these boundaries.
Document native UI labels and code paths that exist in this checkout.
