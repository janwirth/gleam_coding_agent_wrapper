import claude
import envoy
import gleam/option.{None, Some}
import gleeunit/should

pub fn new_codex_run_test() {
  let config =
    claude.Config(".", "Do work", None, Some("Rules"), Some("codex"), None)
  claude.codex_args(config)
  |> should.equal([
    "exec", "--json", "--sandbox", "workspace-write", "-c",
    "agents.default_subagent_reasoning_effort=\"low\"", "-c",
    "agents.max_concurrent_threads_per_session=2", "Rules\n\nDo work",
  ])
}

pub fn resume_codex_run_test() {
  let config =
    claude.Config(
      ".",
      "Continue",
      Some("codex:session"),
      None,
      Some("codex"),
      None,
    )
  claude.codex_args(config)
  |> should.equal([
    "exec",
    "resume",
    "--json",
    "-c",
    "agents.default_subagent_reasoning_effort=\"low\"",
    "-c",
    "agents.max_concurrent_threads_per_session=2",
    "session",
    "Continue",
  ])
}

pub fn codex_stream_fixture_test() {
  case envoy.get("EMPRESS_MOCK_CODEX") {
    Error(_) -> Nil
    Ok(_) -> {
      let config = claude.Config(".", "test", None, None, Some("codex"), None)
      let assert Ok(run) = claude.start_claude(config, fn(_) { Nil })
      run.text |> should.equal("Fixture complete")
      run.session_id |> should.equal("codex:fixture-session")
      run.is_error |> should.be_false
    }
  }
}

pub fn explicit_model_test() {
  let config =
    claude.Config(".", "Work", None, None, Some("codex:gpt-6.1-sol"), None)
  claude.is_codex_model(config.model) |> should.be_true
  claude.codex_args(config)
  |> should.equal([
    "exec",
    "--json",
    "--sandbox",
    "workspace-write",
    "--model",
    "gpt-6.1-sol",
    "-c",
    "agents.default_subagent_reasoning_effort=\"low\"",
    "-c",
    "agents.max_concurrent_threads_per_session=2",
    "Work",
  ])
}
