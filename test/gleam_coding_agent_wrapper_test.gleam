import claude
import envoy
import gleam/erlang/process
import gleam/option.{None, Some}
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
      extra_args: [],
    )
  let assert Ok(res) = claude.start_claude(cfg, fn(_) { Nil })
  assert res.is_error == False
  assert string.contains(res.text, "PONG")
  Nil
}

/// A cancel ends the run at once, with the CLI's whole process group.
pub fn cancel_test() {
  case envoy.get("CLAUDE_BIN") {
    Error(_) -> Nil
    Ok(_) -> {
      let cancel = process.new_subject()
      let cfg =
        claude.Config(
          ..claude.config(
            ".",
            "Run the shell command `sleep 600`, then say done.",
          ),
          cancel: Some(cancel),
          extra_args: ["--tools", "Bash"],
        )
      process.spawn(fn() {
        process.sleep(8000)
        process.send(cancel, Nil)
      })
      let assert Error(claude.Canceled) =
        claude.start_claude(cfg, fn(_) { Nil })
      Nil
    }
  }
}
