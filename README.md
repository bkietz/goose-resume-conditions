# Goose coroutines with resume conditions

This is a modification to the main Goose coroutines proposal,
<https://github.com/aardappel/goose/blob/master/docs/design/coroutines.md>
Although I find that proposal compelling, some aspects of it seemed open
to improvement.

The original design uses shared Wait/Event enums as the coroutine-scheduler
protocol. This proposal replaces them with named resume conditions — typed
contracts that declare exactly what each suspension point needs and how it
must be resumed. This makes the interface between coroutines and schedulers
explicit, type-safe, easier to document, and better encapsulated.

## Terms

- "Scheduler" refers to code which runs in a non-coroutine context
  but which manages and resumes suspended coroutines.
- I'll use "coroutine" to refer to a function which may suspend
  its execution and "task" to refer to the object which represents
  its suspended state when manipulated by a scheduler.
- A task traverses a finite set of "states" corresponding to its
  initialization before any code runs, to each suspension point,
  and to the terminal return condition.
- From the original proposal: "Wait" typed values are sent to the
  scheduler by the coroutine when it suspends. "Event" typed values
  are sent to the coroutine by the scheduler when it is resumed.
  (These were also referred to as the "yield type" and "resume type"
  respectively, but I'll use "Wait" and "Event" exclusively
  for simplicity.)

## Summary

- The scheduler defines its task type with the keyword `suspended`:
  `suspended<Coro>`. The argument is the coroutine function which
  is bundled in the task.

- The scheduler resumes tasks with the new built-in function `resume()`.
  The first argument is always a reference to the resumed task.

- A coroutine library declares `struct`s and `enum`s to communicate
  particular resumption requirements to the scheduler. These messages
  are the "resume conditions" (analogs of Wait variants from the original).

- A coroutine suspends with a `resume if` expression, which communicates
  a requirement to the scheduler then suspends. After resumption, the
  `resume if` expression evaluates to the proof of fulfillment.

- Schedulers define their suspension handling in functions named `on_suspend`.
  When the coroutine suspends, these functions receive a resume condition.
  The scheduler is then responsible for
  fulfilling that condition before resuming the coroutine.

- For each resume condition, the coroutine library also declares an
  overload of `resume()`. The arguments passed to `resume()` after the task
  are the proof that the task's requirements have been met and it should
  resume. The parameters of a `resume()` overload define the type of that proof. 

- When the scheduler calls `resume()`, the condition from which the task
  is resumed is an explicit type argument at the call site. This makes it
  obvious to readers and the type checker which `resume()` overload is intended.

### Echo server example

```goose
// coroutine library:

// Two conditions which coroutines may require before resuming:
struct MessageReceived {};
fn resume<T>(task: own T, condition: suspended::awaiting<MessageReceived>, received: u8[..140]) {}

struct MessageSent { to_send: u8[..140] };
fn resume<T>(task: own T, condiditon: suspended::awaiting<MessageSent>) {}

// A simple coroutine which uses those conditions to asynchronously echo messages.
fn echo() -> const u8[:] {
    loop {
        let received = resume if MessageReceived {};
        if received == "STOP" { return "stopping"; }
        if received == "SAVE" { return "saving"; }
        resume if MessageSent { to_send: received };
    }
}

// scheduler:
fn main() {
    // plug the echo coroutine into a repl for testing
    repl(echo, make_prompt());
}

// This scheduler function is generic; it can schedule any
// message sending coroutine while exposing IO to the user.
fn repl<MessageCoro>(prompt: UserPrompt) {
    type Task = suspended<MessageCoro>;
    var the_task = own_one<Task> {};

    fn on_suspend(task: own Task, m: MessageReceived) {
        the_task.take(task);
        prompt.request_input();
    }
    fn on_suspend(task: own Task, m: MessageSent) {
        the_task.take(task);
        prompt.show_text(m.to_send);
    }
    fn on_suspend(task: Task&, r: suspended::finished<Task>) {
        if (r.value == "saved") { abort("save not implemented"); }
    }

    resume(the_task.release());
    loop {
        while prompt.has_input {
            let user_message = prompt.get_input();
            resume<MessageReceived>(the_task.release(), user_message);
        }
        resume<MessageSent>(the_task.release());
    }
}

```

## Proposed improvements

For a scheduler protocol which is data (§2.7), the values passed
between a coroutine and its scheduler should *primarily* be considered
communication of requirements which must be fulfilled before the
coroutine can/should be resumed. Any other elements of the payload in
a Wait or Event value are incidental. My primary goal is to make this
interpretation more explicit, obvious, and natural.
Several points below derive from this goal.

Note that the interpretation Wait/Event=requirements communication
is in sharp contrast to several other languages. Similarity to
those other languages' coroutines is therefore a potential source
of bias or patterns which don't make as much sense in Goose.
For example, generator functions in Python or JavaScript *are*
coroutines, but they are specialized
for defining lazy sequences. Since Goose's application for
coroutines is not the definition of lazy sequences, similarity
to generator functions is not an unqualified advantage to Goose.

Since Wait/Event=requirements communication, we should make this
obvious and easier to be consistent with than to mess up
(help users fall into the
[pit of success](https://learn.microsoft.com/en-us/archive/blogs/brada/the-pit-of-success)
). I think this includes orienting Goose' coroutines (including
syntax choices) to prioritize Goose' primary use case
over following precedent from other languages.

### Explicitly declare Wait/Event relationships

The original proposal's server code example (§5) defines Wait
and Event types:

```goose
enum Wait  { Readable { fd: i64 }, Writable { fd: i64 }, Timer { deadline_ns: i64 }, Any }
enum Event { Ready, Timeout, Hangup, Cancel }
```

A coroutine yields a Wait to indicate when it should be resumed,
and receives an Event which indicates how the resumed coroutine
should proceed. These declarations alone don't make it clear
which Event types correspond to which Waits. We have to read the
entire coroutine and scheduler to learn that after yielding a
Wait.Readable, a coroutine may be resumed with an Event.Ready
or an Event.Hangup. This implicit relationship (and the
relationships between other Wait/Event pairs) constitutes
strong coupling between writers of coroutine and scheduler code.
A coroutine author will either rely on knowledge of the scheduler
or would write overly defensive code to insulate the coroutine
from changes to the scheduler.

Function calls and suspension points are analogous: Function
calls are a transition between the caller and the callee, while
suspension points are a transition between the
coroutine and the scheduler.
Each function in a program declares the parameter
and return types relevant to calls of that specific function.
Likewise, each suspension point should declare the types
relevant to itself rather than invoking the full union of
types used by any suspension point.
Just like a function, the types involved in a suspension point
should be declared with a specific and documentable funciton
signature. The entry point for resuming a coroutine is the
`resume` built-in, so we declare its signature:

```goose
fn resume<T>(task: own T, condition: suspended::awaiting<MessageReceived>, received: u8[..140]) {}
```

`suspended::awaiting<MessageReceived>` is an empty tag used to include the
condition in the signature. With this declaration, resume will be callable
against any task suspended with the `MessageReceived` condition:
`resume<MessageReceived>(task, "foo")`. `resume()` consumes the task.

A resume overload defines how a scheduler should resume a task suspended
with the resume condition `MessageReceived`. The `echo` coroutine
cannot proceed until a message is received, so it suspends with
this condition. A scheduler can only resume from this condition
by supplying the message which the `echo` coroutine requires,
declared in the `received` argument in this `resume()` overload.
In general, a resume signature
shows precisely how the scheduler should resume the coroutine
with information about how the condition was met.

```goose
struct MessageSent { to_send: u8[..140] };
fn resume<T>(task: own T, condiditon: suspended::awaiting<MessageSent>) {}
```

The resume condition in this signature is `MessageSent`. The `echo`
coroutine suspends in this condition to communicate that it
cannot proceed until `to_send` has been fully transmitted. Note
that the `MessageSent` condition is reusable by coroutines other
than `echo` and by schedulers other than `repl`; it can even be
used in coroutines and schedulers composed of code from multiple
packages. Resume conditions are not only composable, their
declarations are a natural place to attach documentation and
claims pertinent to suspension points which reference them.
These factors will all combine to insulate coroutine authors
from scheduler specifics and provide confidence in the precise
behavior of a resume condition.

Finally, names for resume conditions are more obvious than names
for Wait or Event variants. Variables are named with nouns,
functions are named with verbs, and resume conditions are named with
antecedents. If a coroutine cannot resume until _a message was
received_, then the name for that resume condition should be
`MessageReceived`. A clear naming convention is an understated
boon to comprehensible code.

### Consolidated suspension handling

The original proposal requires that `Wait` values yielded by
suspended coroutines be handled by the scheduler in the same scope
that resumes coroutines (§4.3). This does not reflect the most common
use case for coroutines in goose, where we expect that the scheduler
handles a particular kind of suspension in one particular way
regardless of how a task is resumed.
For example, `Wait.Readable` will likely always be handled by
instructing the OS to watch that file. However, each call to
`resume()` in the scheduler must reiterate this code to correctly
handle the resulting `Wait`. It is more likely is that functions
will be extracted to contain the reused logic for handling yielded
`Wait`s. This probable pattern can be formalized and scheduler
code simplified.

In generic terms, the resume conditions referenced by a coroutine
constitute a trait which must be implemented by a scheduler.
If a coroutine may suspend waiting for a message, then the scheduler
must support fulfilling that condition. I propose that the scheduler
unambiguously declare how it will fulfil each condition its tasks
may require:

```goose
fn repl<MessageCoro>() {
    let prompt = make_prompt();

    type Task = suspended<MessageCoro>;
    var the_task = own_one<Task> {};

    fn on_suspend(task: own Task, m: MessageReceived) {
        the_task.take(task);
        prompt.request_input();
    }
    // ...
}
```

In this example, the parameters of `on_suspend` are:

- the newly suspended `task`, of which the scheduler takes ownership and
- the `condition` value with which the coroutine suspended

The condition argument to `on_suspend` is the analog of a Wait
value, but it does not need to be a variant of an enum at all.
The types declared in `resume()` and `on_suspend()` are sufficient
to relieve the scheduler of unpacking an enum because we always
have full type information about the condition with which the
coroutine suspended.

Note also that this doesn't constitute a function pointer
embedded in the task. `on_suspend` is fully known to the compiler;
it will be inlined by the compiler such that it is run as the final
step in suspending a task before returning from a call to `resume()`.

### Resume conditions make coroutines more reusable across libraries

In the original proposal, a coroutine or a scheduler helper function
will be written against specific Wait/Event types. If those functions
are in a different package from the scheduler, then it will be necessary
to write code which adapts between the library's Wait/Event types and
your own. This would be a significant impediment to writing reusable
coroutine libraries.

Resume conditions are declarations which can be imported just like
functions. This is a more modular way to build coroutines, since a
library's resume condition(s) can be reused directly. Calling a
library coroutine only requires updating the scheduler's suspension
handling to accommodate new resume conditions it suspends in.

Fragments of suspension handling are likewise reusable; a library
could even provide default `on_suspend` functions for their
resume conditions.

### The condition from which a task resumes is explicit

In the original proposal, resume is a function call
taking an Event argument with which the coroutine
will be resumed, `resume(task, Event.Ready)`. It is impossible
for the reader or the type checker to learn from this
expression what Event variant(s) the task is actually waiting on.
Instead, we could make the condition from which we're resuming
explicit in scheduler code:

```goose
resume<MessageReceived>(task, user_message);
```

This obviates an `Event` enum entirely. The specific overload
of `resume` is explicit in each call, so the types of arguments
are fully known.

### The finished state is just another suspended state

The original proposal requires checking
whether each resume() resulted in suspension or in finishing,
and included a separate result() built-in for retrieving
the finished results (§4.3, §4.10).

We don't require a special function to start a
coroutine which has not yet run; `resume()` suffices.
Similarly, it is tidier to consider the finished state as
a specific case of suspension rather than to consider it a
state specially distinct from suspension. By doing so we
can reduce the number of primitives necessary for
interacting with coroutines.

Schedulers of coroutines which may return must include
the finished condition in their suspension handlers:

```goose
fn on_suspend(task: Task&, r: suspended::finished<Task>) {
    if (r.value == "saved") { abort("save not implemented"); }
}
```

Note that the suspension handler for the finished case does *not*
take ownership of the `task`; the task will be discarded now
that it is finished.

### Since tasks are owned, defer across suspension points works

Tasks are `own`ed by the scheduler until they complete.
This removes the concern over dropped `defer`'d code, since the
compiler will emit an error for any task which is not resumed
or cancelled.

Cancellation is an alternative to resuming a task.
The built-in function `cancel(task)` consumes the task and
resumes as though the suspending `resume if` were replaced by
`return default from top_level_coroutine`. This will run just the
active `defer`'d code, finishing the coroutine safely.

### A special function type is not necessary

The original proposal requires coroutines be declared explicitly
with `coro fn f()` (§4.1).

The modifications described above mean that coroutines need not be
declared differently from other functions. The compiler is able to
detect whether a function is a coroutine through static analysis:
a coroutine is any function which includes a `resume if` expression
or which calls a coroutine. Since the compiler knows which functions
are coroutines, the semantics of calling a coroutine from another
coroutine need not change from the original proposal (§4.4).

This is very useful for higher order functions which need not
be declared as `coro fn` either; they can derive their coroutine
status from their bodies instead. For example, in the original
proposal `arr.map() { yield it; }` could not compile because `map`
isn't declared `coro fn`.

One reason given for requiring explicit annotation of coroutines
(§3.6) is to prevent
the unintentional spread of async-ness. However, unlike Zig's async
functions, Goose coroutines cannot be called from `main`, `thread_fn`s,
or any function called anywhere in their call graphs.
Unless already in a coroutine, the only way to call one is by
constructing a task. Therefore the danger does not arise that a
seemingly regular function might stealthily call a coroutine
somewhere deep in its call graph and secretly become a bloated
coroutine itself; a compiler error would be emitted with the
call stack leading from a known-regular function down to the
first function which directly suspends.

Finally, this proposal does not *require* that coroutines be declared
identically to other functions. If it is desired that coroutines
always be declared `coro fn f()` then that changes only the
requirements on the type parameter of `suspended<>`; the rest of
the proposal stands.

## Alternative approaches explored:

### syntax choices

In order to express my intended improvements, I have introduced some new
syntax along with new features. I'm not convinced that the two are
entirely separable; coroutine features like functions which suspend are
arguably "just" syntactic sugar for state machines. Here I'll try to
discuss where the language features I've described could be represented
with alternative syntax choices.

- Resume conditions could be declared differently. Any declaration
  style which includes resume()'s parameters for the condition as
  well as the condition's payload would work.

  For example the `yield_op`
  [proposal](https://discord.com/channels/1559977219663732797/1564380133714952303/1564843783810453504)
  used signatures closer to a function's:
  ```goose
  yield_op check_auth(token: Token) -> AuthResult;
  ```

  An earlier version of this proposal combined resume's signature and
  the payload of its condition into a single new declaration type:
  ```goose
  resume(task, received: u8[..140]) if MessageReceived {};
  ```
  although the syntax is closer to plain English, it was abandoned
  in favor of reusing existing declaration types.

- When calling `resume()`, the condition resumed from could be
  passed in a number of ways.

  The following form was used by the `yield_op`s proposal:
  ```goose
  resume(task, MessageReceived, "foo");
  ```
  ... but uses a type or `yield_op` name in a context which expects a
  value, which is slightly confusing.

  A previous version of this proposal used this syntax:
  ```goose
  as FileWontBlock resume(task, "foo");
  ```
  again, although the syntax is closer to plain English it was abandoned
  to avoid introducing a new statement type.

- I strongly recommend we avoid the `yield` keyword.

  The original proposal uses the `yield` keyword to indicate
  suspension (§4.3).
  In JavaScript and Python, generator functions and the `yield`
  keyword which powers them are primarily specialized for
  defining lazy sequences. Using that keyword inherits the
  connotation of producing the next value in a lazy sequence.
  This is not what Goose will primarily use coroutines for,
  so that connotation should be avoided.

  A language *could* use the keyword `branch` instead of `if` and
  lose no expressiveness. However, of the two possible statements
  `if condition { return; }` and `branch condition { return; }` the
  first is closer to its plain English explanation "if the condition
  holds then return". Similarly, I predict that `resume if`
  will produce less cognitive dissonance than `yield` in the
  long run.

  My misgivings aside, the rest of the proposal would stand if
  `yield MessageSent { text }` were written instead of
  `resume if MessageSent { text }`. 
