import claude_harness
import envoy
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
    claude_harness.Config(
      cwd: ".",
      prompt: "Think briefly, then reply with exactly one word: PONG",
    )
  let assert Ok(res) = claude_harness.start_claude(cfg, fn(_) { Nil })
  assert res.is_error == False
  assert string.contains(res.text, "PONG")
  Nil
}
