import gleam/erlang/process
import server

pub fn main() {
  let assert Ok(_) = server.start(fn(h) { h })
  process.sleep_forever()
}
