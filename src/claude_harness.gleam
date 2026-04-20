import child_process
import child_process/stdio
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Config {
  Config(cwd: String, prompt: String)
}

pub type Event {
  SystemInit(session_id: String, model: String)
  AssistantText(text: String)
  ToolUse(tool: String, input: Dynamic)
}

pub type RunResult {
  RunResult(session_id: String, text: String, is_error: Bool, cost_usd: Float)
}

pub type Error {
  SpawnFailed(reason: String)
  NonZeroExit(code: Int)
}

type Msg {
  Line(String)
  Exit(Int)
}

pub fn start_claude(
  config: Config,
  on_event: fn(Event) -> Nil,
) -> Result(RunResult, Error) {
  let subj: Subject(Msg) = process.new_subject()

  let stdio_cfg =
    stdio.lines(fn(line) { process.send(subj, Line(line)) })
    |> stdio.on_exit(fn(code) { process.send(subj, Exit(code)) })

  let builder =
    child_process.from_name("claude")
    |> child_process.cwd(config.cwd)
    |> child_process.args([
      "-p",
      config.prompt,
      "--output-format",
      "stream-json",
      "--verbose",
      "--dangerously-skip-permissions",
    ])

  case child_process.spawn(builder, stdio_cfg) {
    Error(e) -> Error(SpawnFailed(start_error_to_string(e)))
    Ok(_proc) -> drain(subj, State("", None), on_event)
  }
}

type State {
  State(session_id: String, final: Option(#(String, String, Bool, Float)))
}

fn drain(
  subj: Subject(Msg),
  state: State,
  on_event: fn(Event) -> Nil,
) -> Result(RunResult, Error) {
  case process.receive_forever(subj) {
    Line(s) -> drain(subj, handle_line(s, state, on_event), on_event)
    Exit(n) -> finalize(state, n)
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
    _ ->
      case json.parse(s, stream_decoder()) {
        Error(_) -> state
        Ok(msg) -> apply_msg(msg, state, on_event)
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
          BlockTool(n, i) -> on_event(ToolUse(n, i))
          BlockOther -> Nil
        }
      })
      state
    }
    Res(sid, t, e, c) -> State(..state, final: Some(#(sid, t, e, c)))
    MsgOther -> state
  }
}

type StreamMsg {
  Sys(session_id: String, model: String)
  Asst(content: List(ContentBlock))
  Res(session_id: String, text: String, is_error: Bool, cost: Float)
  MsgOther
}

type ContentBlock {
  BlockText(text: String)
  BlockTool(name: String, input: Dynamic)
  BlockOther
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
    "tool_use" -> {
      use name <- decode.field("name", decode.string)
      use input <- decode.field("input", decode.dynamic)
      decode.success(BlockTool(name, input))
    }
    _ -> decode.success(BlockOther)
  }
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
