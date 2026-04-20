import argv
import claude_harness
import gleam/float
import gleam/int
import gleam/io
import gleam/string

pub fn main() {
  case argv.load().arguments {
    [prompt] -> run(".", prompt)
    [cwd, prompt] -> run(cwd, prompt)
    _ ->
      io.println_error(
        "usage: gleam run -m claude_harness/cli -- [cwd] <prompt>",
      )
  }
}

fn run(cwd: String, prompt: String) -> Nil {
  let cfg = claude_harness.Config(cwd, prompt)
  case claude_harness.start_claude(cfg, print_event) {
    Ok(r) ->
      io.println(
        "result\t"
        <> bool_str(r.is_error)
        <> "\t"
        <> float.to_string(r.cost_usd)
        <> "\t"
        <> escape(r.text),
      )
    Error(claude_harness.SpawnFailed(m)) ->
      io.println_error("error\tspawn\t" <> m)
    Error(claude_harness.NonZeroExit(n)) ->
      io.println_error("error\texit\t" <> int.to_string(n))
  }
}

fn print_event(e: claude_harness.Event) -> Nil {
  case e {
    claude_harness.SystemInit(sid, m) ->
      io.println("system\t" <> sid <> "\t" <> m)
    claude_harness.AssistantText(t) -> io.println("text\t" <> escape(t))
    claude_harness.ToolUse(n, i) ->
      io.println("tool\t" <> n <> "\t" <> string.inspect(i))
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
