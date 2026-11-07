# Agent Instructions: Goose Resume Conditions Worked Examples

This repository contains a proposal to improve the coroutine
scheduling protocol in the
[Goose](https://github.com/aardappel/goose) programming
language. The proposal, described in `README.md`, replaces
opaque shared `Wait`/`Event` enums with named, type-safe
"resume conditions" that make scheduler-coroutine contracts
explicit.

Your job is to generate first-draft worked examples that
illustrate the before-and-after transformation. Every
example must be self-contained and clearly demonstrate *why*
resume conditions are an improvement.

---

## Repository Layout

```text
goose-resume-conditions/
  README.md                          # The proposal itself — read this thoroughly
  AGENTS.md                          # This file — your instructions
  <example-name>/                    # One directory per worked example
    foo.before.goose                 # Original design (shared Wait/Event enums)
    foo.after.goose                  # Improved design (named resume conditions)
    README.md                        # Explains what this example demonstrates
```

Where `foo` is the lowercase-kebab-case name of the example,
e.g. `timer`, `server-loop`, etc.

---

## Reference Material

All examples must be consistent with the following sources.
Read them before writing any code:

| File | Purpose |
|------|---------|
| `README.md` (this repo) | The resume-conditions proposal — **primary source of truth for "after" syntax** |
| `serve/serve_example.before.goose` (this repo) | A slightly expanded copy of the serve example from the original proposal |
| `serve/serve_example.after.goose` (this repo) | The serve example, rewritten using this proposal |
| `../goose/docs/design/coroutines.md` | Original coroutine design — **source of truth for "before" syntax** and semantics |
| `../goose/docs/design/ownership.md` | Description of new checked `own`ership feature |
| `../goose/docs/reference.md` | Full Goose language reference (syntax, types, lifetimes, functions, threads) |
| `../goose/docs/stdlib.md` | Standard library structure |
| `../goose/docs/goose_spec.md` | v4 spec: priorities (Speed, Safety, Expressiveness), compilation model, core concepts |

When in doubt about Goose syntax or semantics, prefer the v4 spec and reference over other sources.

---

## Core Design Shift

Every example must clearly illustrate this transformation:

### Before: Shared Wait/Event enums

```goose
enum Wait  { Readable { fd: i64 }, Writable { fd: i64 }, Timer { deadline_ns: i64 }, Any }
enum Event { Ready, Timeout, Hangup, Cancel }

coro fn serve(c: Conn&) yield Wait resume Event {
    let ev = yield Wait.Readable { fd: c.fd };
    match ev { /* ... */ }
}
```

Wait and Event are global unions shared across *all*
coroutines. The mapping between which Wait yields which
possible Events is implicit — you must read the full
scheduler to discover it.

### After: Named resume conditions and resume fn overloads

```goose
struct FileWontBlock { fd: i64, flags: net::Flags }
fn resume<T>(task: own T, condition: suspended::awaiting<FileWontBlock>) {}

fn serve(c: Conn&) -> bool {
    resume<FileWontBlock>(task);  // explicit which condition we're resuming from
}
```

Each suspension point declares exactly what it needs and how
it expects to be resumed. No global enums needed —
conditions are named, typed contracts that can be imported
across modules.

---

## Ground Rules for Generated Examples

### File Naming Conventions

- Directory: `<name>/` where `<name>` is a lowercase noun or
  noun phrase in kebab case
  - Good: `timer`, `server-loop`, `read-line`,
    `cooperative-cancellation`, `nested-await`
  - Bad: `Example1`, `test_timer`, `Timer`
- Before file: `<name>.before.goose` (no spaces, no
  extension ambiguity)
- After file: `<name>.after.goose`
- README: `README.md` inside the example directory

### Code Style — Goose

All `.goose` files must follow consistent style:

1. **Indentation**: 4 spaces (consistent with references).
   No tabs.
2. **Module imports**: At file top, before type/function
   declarations.
3. **Type annotations**: Be explicit where readability
   demands it; don't over-annotate trivial expressions.
4. **Comments**: Inline comments explaining *why*, not
   *what*. The pair-of-files structure already shows what
   changed.
5. **Consistent names**: Use the same variable and function
   names in `.before` and `.after` versions so diffs are
   easy to read. Only change identifiers where the proposal
   mandates new names (e.g., `yield` → `resume if`).
6. **Completeness for compilability**: Show enough
   surrounding code (type definitions, struct fields, pool
   declarations) that a reader could compile the example
   with minimal additions. Do *not* write a full production
   server in every file — focus on what illustrates the
   change.

### Code Style — READMEs

Each `README.md` inside an example directory must contain:

```markdown
# <Example Name>

## What it demonstrates
[1-2 sentences explaining which problem this example highlights]

## Transformation summary
[Bullet points mapping before → after for key patterns shown]

## Before
[Link to foo.before.goose, explain the shared enum pain point in this context]

[goose](foo.before.goose#LXX-LYY "specific code section")

## After
[Link to foo.after.goose, explain how resume conditions improve it]

[goose](foo.after.goose#LXX-LYY "specific code section")

## Key takeaways
- [What the reader should notice about this transformation]
```

Links to specific code sections use line-range anchors:
`filename.ext#L10-L25`.

---

## Technical Constraints & Correctness

### Goose v4 Semantics — Must Be Obeyed

1. **Stackless coroutines**: Coroutines are compiled to
   state machines, not stackful fibers. No implicit heap
   allocation for frames.
2. **No Pin analog**: Goose avoids self-borrows across
   suspension by rule (R4). No reference into a coroutine's
   own locals may live across a yield/resume-if.
3. **Pools own growable data** (§2.6): Coroutines cannot
   hold `u8[>..]` or resizable arrays across suspension
   points. Buffers live in pools; coroutines hold references
   or pool indices.
4. **Fixed-size protocol values**: Wait/Event payloads and
   resume condition payloads are all fixed-size. No strings,
   no dynamic arrays, no growable types crossing the
   boundary.
5. **Thread-per-core model** (§2.5): The scheduler runs on a
   single thread; one event loop per worker. No
   work-stealing between threads.
6. **No function pointers**: Scheduler protocol is data, not
   callbacks ( §2.7).

### Before Examples — Must Use the Original Design

- `enum Wait { ... }` and `enum Event { ... }` declarations
  for shared protocol types
- `coro fn serve() yield Wait resume Event` signatures
- `let ev = yield Wait.SomeVariant { field: value };` for
  suspension
- `resume(task, event)` for resumption
- `result(task)` for reading finished results

Refer to §4.1–§4.13 and the server example in §5 of
`coroutines.md`.

### After Examples — Must Use Resume Conditions

- Named resume conditions:
  `struct ConditionName { ...payload_fields... }`
- Suspension: `resume if ConditionName { ... }` syntax (NOT `yield`)
- Resumption from scheduler:
  `resume<ConditionName>(task, proof_of_completion)` or equivalent per README.md
- Suspension handler: `on_suspend(task, condition: ConditionName)` function
- Finished state handled as just another suspension handler
- Coroutines declared as regular `fn` — no `coro fn` prefix
  needed since compiler detects them by presence of
  `resume if`

Refer to `README.md` for all proposed syntax. If a specific
detail is ambiguous in the proposal, write a comment noting
the assumption.

### Cross-Example Consistency

When multiple examples reference the same concepts (e.g.,
file I/O conditions, timers), use
**consistent type names and field layouts** across all
examples:

- `FileWontBlock` with fields
  `{ fd: i64, flags: net::Flags }` wherever file readiness
  appears
- `TimeElapsed` with fields `{ time: i64 }` wherever timers
  appear
- `ConnectionReady` for network connection availability
- Keep pool types and global patterns consistent too

This makes examples readable as a cohesive set rather than
isolated fragments.

---

## Example Categories to Cover

Generate examples spanning these categories (not every
single one, but diverse coverage):

| Category | What it shows | Suggested focus |
|----------|--------------|-----------------|
| **Basic suspension/resumption** | Fundamental before/after for a simple suspend-and-wait pattern | A coroutine that waits for an I/O event and resumes when ready |
| **Multiple resume conditions** | A coroutine using several different named conditions vs. one big enum | e.g., file ready OR timer expired — show how each condition is typed separately |
| **Scheduler consolidation** | How `on_suspend` eliminates per-resume match logic | Show the before pattern with repeated matching in each resume call vs. a single handler |
| **Coroutine reuse across libraries** | Importing resume conditions from other modules | A library coroutine's condition being reused in a different scheduler |
| **Completed state as suspension** | Treating finish as just another suspension case vs. special-casing `result()` | Show how the after design reduces API surface |
| **Nested coroutine calls** | One coroutine calling another — inline splicing before and after | Demonstrates the rule about called coroutines being inlined into caller's state machine |

---

## Checklist Before Submitting an Example

For every `<name>/` directory you create:

- [ ] Directory name is lowercase kebab case
- [ ] `<name>.before.goose` exists with original Wait/Event
      enum design
- [ ] `<name>.after.goose` exists with resume condition
      design
- [ ] `README.md` exists with all required sections (What it
      demonstrates, Transformation summary, Before, After,
      Key takeaways)
- [ ] README links to specific line ranges in `.goose` files
      using `#LXX-LYY` anchors
- [ ] Variable/function names are consistent between before
      and after versions
- [ ] No Goose v4 violations (no Pin issues, pool rules
      respected, fixed-size payloads only)
- [ ] Before code uses `coro fn`, `yield`, shared enums per
      §4 of `coroutines.md`
- [ ] After code uses regular `fn`, `resume if`, named
      conditions, `on_suspend` per `README.md`
- [ ] Type names are consistent with other examples
      (`FileWontBlock`, `TimeElapsed`, etc.)
- [ ] Comments explain *why* not *what*

---

## Tone and Audience

- **Audience**: Goose language designers (primarily
  aardappel), systems programmers familiar with stackless
  coroutines, Rust async/await, or C++ coroutine authors
- **Tone**: Technical, precise, no marketing language. Every
  claim should be demonstrable from the code shown.
- **Assume familiarity** with basic Goose syntax but not
  necessarily with coroutine internals
