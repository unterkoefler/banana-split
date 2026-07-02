import gleam/erlang/process
import server

pub fn main() {
  let assert Ok(_) = server.start(fn(h) { h }, allow_all_origins: False)
  process.sleep_forever()
}
