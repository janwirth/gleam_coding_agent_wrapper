import argv
import claude
import gleam/float
import gleam/int
import gleam/io
import gleam/option.{None}
import gleam/string

pub fn main() {
  case argv.load().arguments {
    [prompt] -> run(".", prompt)
    [cwd, prompt] -> run(cwd, prompt)
    _ -> io.println_error("usage: gleam run -m claude/cli -- [cwd] <prompt>")
  }
}

fn run(cwd: String, prompt: String) -> Nil {
  let cfg = claude.Config(cwd, prompt, None, None, None, None)
  case claude.start_claude(cfg, print_event) {
    Ok(r) ->
      io.println(
        "result\t"
        <> bool_str(r.is_error)
        <> "\t"
        <> float.to_string(r.cost_usd)
        <> "\t"
        <> escape(r.text),
      )
    Error(claude.SpawnFailed(m)) -> io.println_error("error\tspawn\t" <> m)
    Error(claude.NonZeroExit(n)) ->
      io.println_error("error\texit\t" <> int.to_string(n))
    Error(claude.Canceled) -> io.println_error("error\tcanceled")
  }
}

fn print_event(e: claude.Event) -> Nil {
  case e {
    claude.SystemInit(sid, m) -> io.println("system\t" <> sid <> "\t" <> m)
    claude.AssistantText(t) -> io.println("text\t" <> escape(t))
    claude.AssistantThinking(t) -> io.println("thinking\t" <> escape(t))
    claude.ToolUse(n, id, i) ->
      io.println("tool\t" <> n <> "\t" <> id <> "\t" <> string.inspect(i))
    claude.ToolResult(id, c, err) ->
      io.println(
        "tool_result\t" <> id <> "\t" <> bool_str(err) <> "\t" <> escape(c),
      )
    claude.Finished(err, cost) ->
      io.println("finished\t" <> bool_str(err) <> "\t" <> float.to_string(cost))
    claude.RawLine(_) -> Nil
  }
}

fn escape(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\n", "\\n")
  |> string.replace("\t", "\\t")
}

fn bool_str(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}
