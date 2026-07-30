import wisp

pub fn middleware(
  req: wisp.Request,
  static_directory: String,
  handle_request: fn(wisp.Request) -> wisp.Response,
  allow_all_origins allow_all_origins: Bool,
) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  //use req <- wisp.csrf_known_header_protection(req)
  use <- wisp.serve_static(req, under: "/static", from: static_directory)

  case allow_all_origins {
    True -> {
      handle_request(req)
      |> wisp.set_header("Access-Control-Allow-Origin", "*")
      |> wisp.set_header("Access-Control-Allow-Headers", "Content-Type")
    }
    False -> {
      handle_request(req)
    }
  }
}
