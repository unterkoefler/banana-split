import glyn/registry
import mist
import router
import shared as api
import wisp
import wisp_mist

pub fn start(wrap_reload) {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)

  let registry =
    registry.new(
      scope: "rooms",
      decoder: router.message_decoder(),
      error_default: api.Close,
    )

  let assert Ok(priv_directory) = wisp.priv_directory("banana_split_server")
  let static_directory = priv_directory <> "/static"

  let ctx = router.Context(registry:, static_directory:)

  let assert Ok(_) =
    router.handle_request(_, ctx)
    |> wisp_mist.handler(secret_key_base)
    |> wrap_reload()
    |> mist.new
    |> mist.bind("0.0.0.0")
    |> mist.port(8000)
    |> mist.start
}
