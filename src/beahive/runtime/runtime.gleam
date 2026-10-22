// src/beahive/runtime/runtime.gleam
import gleam/erlang/atom

@external(erlang, "ffi", "app_version")
pub fn app_version(app_name: atom.Atom) -> String
