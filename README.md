# gleam_coding_agent_wrapper

Gleam wrappers around coding-agent CLIs. Currently exposes a single public
module: `claude` — embed the `claude` CLI as a BEAM subprocess and stream
its events.

```gleam
import claude

pub fn main() -> Nil {
  // see SPEC.md
  Nil
}
```

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```
