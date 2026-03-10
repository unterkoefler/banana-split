import mist
import wisp
import wisp/wisp_mist
import router

pub fn start(wrap_reload) {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)

  let assert Ok(_) =
    wisp_mist.handler(router.handle_request, secret_key_base)
    |> wrap_reload()
    |> mist.new
    |> mist.port(8000)
    |> mist.start
}
