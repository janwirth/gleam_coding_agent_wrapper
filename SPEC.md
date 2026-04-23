# gleam_coding_agent_wrapper — Spec

Gleam lib. Embed coding-agent CLIs as BEAM subprocesses, stream events,
terminate on final message. Currently the only public module is `claude`,
which wraps the `claude` CLI.

## Flow

`start_claude(config)` → spawn `claude` in cwd via Port → stream NDJSON stdout → decode → emit events → on final `result` line, return `RunResult`, close port, stop actor.

One actor per run. Actor lifetime = subprocess lifetime.

## API

```gleam
pub type Config {
  Config(cwd: String, prompt: String)
}

pub type Event {
  SystemInit(session_id: String, model: String)
  AssistantText(text: String)
  ToolUse(tool: String, input: Dynamic)   // for live UI only
}

pub type RunResult {
  RunResult(session_id: String, text: String, is_error: Bool, cost_usd: Float)
}

pub type Error { SpawnFailed(String) NonZeroExit(Int) }

pub fn start_claude(Config, on_event: fn(Event) -> Nil) -> Result(RunResult, Error)
```

## Spawned CLI args

```
claude -p <prompt>
  --output-format stream-json
  --verbose
  --dangerously-skip-permissions
```

Spawn with `{cd, cwd}`. Caller's PATH/env carries any CLI bins Claude should call via Bash.

## Stream-JSON

NDJSON, one object per stdout line. Dispatch on `type`:
- `system` → `SystemInit`
- `assistant` → `AssistantText` or `ToolUse`
- `user` → ignore (tool results consumed by Claude)
- `result` → finalize `RunResult`, stop

Unknown types: ignore.

## Test CLI

`gleam run -m claude/cli -- <prompt>` (cwd = pwd).

Output: one line per event, no prefix/color/decor. Flushed as it arrives.

```
system  <session_id>  <model>
text    <one-line text, newlines escaped>
tool    <name>  <json input>
result  <is_error>  <cost_usd>  <final text, one line>
```

## Unit test

`test/gleam_coding_agent_wrapper_test.gleam` — gated on `CLAUDE_BIN` env (skip if unset).

Case: `start_claude(Config(cwd: tmp, prompt: "Think briefly, then reply with the single word PONG."))`.

Assert:
- at least one `AssistantText` event received
- `RunResult.is_error == False`
- `RunResult.text` contains `"PONG"`


## Cleanup

Final `result` → close port, return. Caller process crash → Port auto-closes (linked). Bad exit + no `result` → `NonZeroExit`.

## Out of scope

MCP servers, iframe tool, resume, multi-turn, model selection.
