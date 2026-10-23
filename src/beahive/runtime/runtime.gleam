// src/beahive/runtime/runtime.gleam
import ewe
import gleam/erlang/atom

@external(erlang, "beahive_ffi", "app_version")
pub fn app_version(app_name: atom.Atom) -> String

@external(erlang, "beahive_ffi", "parse_ip")
pub fn parse_ip(text: String) -> Result(ewe.IpAddress, Nil)
