import child_process
import child_process/stdio
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Config {
  Config(
    cwd: String,
    prompt: String,
    resume: Option(String),
    append_system_prompt: Option(String),
    model: Option(String),
    cancel: Option(Subject(Nil)),
  )
}

/// Models selectable via `--model`. Values are the aliases / IDs
/// that the `claude` CLI accepts directly. Callers typically render
/// these as buttons in a UI.
pub type Model {
  Model(label: String, id: String)
}

/// Curated list of models the harness exposes to UIs. Uses aliases
/// where a stable alias exists; pin to a specific version otherwise.
pub fn models() -> List(Model) {
  [
    Model(label: "opus", id: "opus"),
    Model(label: "sonnet", id: "sonnet"),
    Model(label: "haiku", id: "haiku"),
  ]
}

pub type Event {
  SystemInit(session_id: String, model: String)
  AssistantText(text: String)
  AssistantThinking(text: String)
  ToolUse(tool: String, id: String, input: Dynamic)
  ToolResult(tool_use_id: String, content: String, is_error: Bool)
  RawLine(line: String)
  Finished(is_error: Bool, cost_usd: Float)
}

pub type RunResult {
  RunResult(session_id: String, text: String, is_error: Bool, cost_usd: Float)
}

pub type Error {
  SpawnFailed(reason: String)
  NonZeroExit(code: Int)
  Canceled
}

type Msg {
  Line(String)
  Exit(Int)
  Cancel
}

pub fn start_claude(
  config: Config,
  on_event: fn(Event) -> Nil,
) -> Result(RunResult, Error) {
  let subj: Subject(Msg) = process.new_subject()

  let stdio_cfg =
    stdio.lines(fn(line) { process.send(subj, Line(line)) })
    |> stdio.on_exit(fn(code) { process.send(subj, Exit(code)) })

  let base_args = [
    "-p",
    config.prompt,
    "--output-format",
    "stream-json",
    "--verbose",
    "--dangerously-skip-permissions",
  ]
  let args_with_resume = case config.resume {
    Some(sid) -> ["--resume", sid, ..base_args]
    None -> base_args
  }
  let args_with_sp = case config.append_system_prompt {
    Some(sp) -> ["--append-system-prompt", sp, ..args_with_resume]
    None -> args_with_resume
  }
  let args = case config.model {
    Some(m) -> ["--model", m, ..args_with_sp]
    None -> args_with_sp
  }
  let builder =
    child_process.from_name("claude")
    |> child_process.cwd(config.cwd)
    |> child_process.args(args)

  case child_process.spawn(builder, stdio_cfg) {
    Error(e) -> Error(SpawnFailed(start_error_to_string(e)))
    Ok(proc) -> drain(subj, config.cancel, proc, State("", None), on_event)
  }
}

type State {
  State(session_id: String, final: Option(#(String, String, Bool, Float)))
}

fn drain(
  subj: Subject(Msg),
  cancel: Option(Subject(Nil)),
  proc: child_process.Process,
  state: State,
  on_event: fn(Event) -> Nil,
) -> Result(RunResult, Error) {
  let base_sel = process.new_selector() |> process.select(subj)
  let sel = case cancel {
    Some(cs) -> {
      let cs_sel = process.new_selector() |> process.select(cs)
      let cs_sel = process.map_selector(cs_sel, fn(_nil) { Cancel })
      process.merge_selector(base_sel, cs_sel)
    }
    None -> base_sel
  }
  case process.selector_receive_forever(sel) {
    Line(s) ->
      drain(subj, cancel, proc, handle_line(s, state, on_event), on_event)
    Exit(n) -> finalize(state, n)
    Cancel -> {
      child_process.kill(proc)
      Error(Canceled)
    }
  }
}

fn finalize(state: State, exit_code: Int) -> Result(RunResult, Error) {
  case state.final, exit_code {
    Some(#(sid, t, e, c)), 0 -> Ok(RunResult(sid, t, e, c))
    Some(#(sid, t, _, c)), _ -> Ok(RunResult(sid, t, True, c))
    None, 0 -> Ok(RunResult(state.session_id, "", True, 0.0))
    None, n -> Error(NonZeroExit(n))
  }
}

fn handle_line(
  s: String,
  state: State,
  on_event: fn(Event) -> Nil,
) -> State {
  case s {
    "" -> state
    _ -> {
      on_event(RawLine(s))
      case json.parse(s, stream_decoder()) {
        Error(_) -> state
        Ok(msg) -> apply_msg(msg, state, on_event)
      }
    }
  }
}

fn apply_msg(
  msg: StreamMsg,
  state: State,
  on_event: fn(Event) -> Nil,
) -> State {
  case msg {
    Sys(sid, model) -> {
      on_event(SystemInit(sid, model))
      State(..state, session_id: sid)
    }
    Asst(blocks) -> {
      list.each(blocks, fn(b) {
        case b {
          BlockText(t) -> on_event(AssistantText(t))
          BlockThinking(t) -> on_event(AssistantThinking(t))
          BlockTool(n, id, i) -> on_event(ToolUse(n, id, i))
          BlockOther -> Nil
        }
      })
      state
    }
    Usr(blocks) -> {
      list.each(blocks, fn(b) {
        case b {
          UserToolResult(id, c, e) -> on_event(ToolResult(id, c, e))
          UserOther -> Nil
        }
      })
      state
    }
    Res(sid, t, e, c) -> {
      on_event(Finished(e, c))
      State(..state, final: Some(#(sid, t, e, c)))
    }
    MsgOther -> state
  }
}

type StreamMsg {
  Sys(session_id: String, model: String)
  Asst(content: List(ContentBlock))
  Usr(content: List(UserBlock))
  Res(session_id: String, text: String, is_error: Bool, cost: Float)
  MsgOther
}

type ContentBlock {
  BlockText(text: String)
  BlockThinking(text: String)
  BlockTool(name: String, id: String, input: Dynamic)
  BlockOther
}

type UserBlock {
  UserToolResult(id: String, content: String, is_error: Bool)
  UserOther
}

fn stream_decoder() -> Decoder(StreamMsg) {
  use t <- decode.field("type", decode.string)
  case t {
    "system" -> {
      use sub <- decode.optional_field("subtype", "", decode.string)
      case sub {
        "init" -> {
          use sid <- decode.field("session_id", decode.string)
          use model <- decode.optional_field("model", "", decode.string)
          decode.success(Sys(sid, model))
        }
        _ -> decode.success(MsgOther)
      }
    }
    "assistant" -> {
      use content <- decode.subfield(
        ["message", "content"],
        decode.list(block_decoder()),
      )
      decode.success(Asst(content))
    }
    "user" -> {
      use content <- decode.subfield(
        ["message", "content"],
        decode.list(user_block_decoder()),
      )
      decode.success(Usr(content))
    }
    "result" -> {
      use sid <- decode.field("session_id", decode.string)
      use text <- decode.optional_field("result", "", decode.string)
      use err <- decode.optional_field("is_error", False, decode.bool)
      use cost <- decode.optional_field("total_cost_usd", 0.0, decode.float)
      decode.success(Res(sid, text, err, cost))
    }
    _ -> decode.success(MsgOther)
  }
}

fn block_decoder() -> Decoder(ContentBlock) {
  use t <- decode.field("type", decode.string)
  case t {
    "text" -> {
      use txt <- decode.field("text", decode.string)
      decode.success(BlockText(txt))
    }
    "thinking" -> {
      use txt <- decode.field("thinking", decode.string)
      decode.success(BlockThinking(txt))
    }
    "tool_use" -> {
      use name <- decode.field("name", decode.string)
      use id <- decode.optional_field("id", "", decode.string)
      use input <- decode.field("input", decode.dynamic)
      decode.success(BlockTool(name, id, input))
    }
    _ -> decode.success(BlockOther)
  }
}

fn user_block_decoder() -> Decoder(UserBlock) {
  use t <- decode.field("type", decode.string)
  case t {
    "tool_result" -> {
      use id <- decode.optional_field("tool_use_id", "", decode.string)
      use content <- decode.optional_field(
        "content",
        "",
        decode.one_of(decode.string, or: [tool_result_blocks_decoder()]),
      )
      use err <- decode.optional_field("is_error", False, decode.bool)
      decode.success(UserToolResult(id, content, err))
    }
    _ -> decode.success(UserOther)
  }
}

fn tool_result_blocks_decoder() -> Decoder(String) {
  decode.list({
    use t <- decode.field("type", decode.string)
    case t {
      "text" -> {
        use txt <- decode.field("text", decode.string)
        decode.success(txt)
      }
      _ -> decode.success("")
    }
  })
  |> decode.map(fn(parts) {
    list.fold(parts, "", fn(acc, p) {
      case acc, p {
        "", _ -> p
        _, "" -> acc
        _, _ -> acc <> "\n" <> p
      }
    })
  })
}

fn start_error_to_string(e: child_process.StartError) -> String {
  case e {
    child_process.FileNotFound(s) -> "file not found: " <> s
    child_process.FileNotExecutable(s) -> "not executable: " <> s
    child_process.OutOfMemory -> "out of memory"
    child_process.OsProcessLimitReached -> "os process limit"
    child_process.OsFileLimitReached -> "os file limit"
    child_process.CommandTooLong -> "command too long"
    child_process.NotEnoughFileDescriptors -> "not enough fds"
    child_process.RuntimeLimitReached -> "runtime limit"
  }
}
