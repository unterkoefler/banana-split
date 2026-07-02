import gleam/erlang/process
import mist/reload
import server

pub fn main() {
  let assert Ok(_) = server.start(reload.wrap, allow_all_origins: True)
  process.sleep_forever()
}
