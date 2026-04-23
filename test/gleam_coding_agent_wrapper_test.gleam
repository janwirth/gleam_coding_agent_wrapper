import claude
import envoy
import gleam/option.{None}
import gleam/string
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn pong_test() {
  case envoy.get("CLAUDE_BIN") {
    Error(_) -> Nil
    Ok(_) -> run_pong()
  }
}

fn run_pong() -> Nil {
  let cfg =
    claude.Config(
      cwd: ".",
      prompt: "Think briefly, then reply with exactly one word: PONG",
      resume: None,
      append_system_prompt: None,
      model: None,
      cancel: None,
    )
  let assert Ok(res) = claude.start_claude(cfg, fn(_) { Nil })
  assert res.is_error == False
  assert string.contains(res.text, "PONG")
  Nil
}
