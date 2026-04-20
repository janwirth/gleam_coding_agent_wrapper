import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
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

type Port

type Next {
  Line(BitArray)
  Partial(BitArray)
  Exit(Int)
}

@external(erlang, "claude_harness_ffi", "start")
fn ffi_start(cwd: String, prompt: String) -> Result(Port, String)

@external(erlang, "claude_harness_ffi", "next")
fn ffi_next(port: Port) -> Next

pub fn start_claude(
  config: Config,
  on_event: fn(Event) -> Nil,
) -> Result(RunResult, Error) {
  case ffi_start(config.cwd, config.prompt) {
    Error(msg) -> Error(SpawnFailed(msg))
    Ok(port) -> drain(port, <<>>, State("", None), on_event)
  }
}

type State {
  State(session_id: String, final: Option(#(String, String, Bool, Float)))
}

fn drain(
  port: Port,
  buf: BitArray,
  state: State,
  on_event: fn(Event) -> Nil,
) -> Result(RunResult, Error) {
  case ffi_next(port) {
    Line(bin) -> {
      let full = <<buf:bits, bin:bits>>
      let state = handle_line(full, state, on_event)
      drain(port, <<>>, state, on_event)
    }
    Partial(bin) -> drain(port, <<buf:bits, bin:bits>>, state, on_event)
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
  bin: BitArray,
  state: State,
  on_event: fn(Event) -> Nil,
) -> State {
  case bit_array.to_string(bin) {
    Error(_) -> state
    Ok("") -> state
    Ok(s) ->
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
