import mist
import router
import wisp
import wisp_mist
import glyn/registry

pub fn start(wrap_reload) {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)

  let registry = registry.new(
    scope: "rooms",
    decoder: router.message_decoder(),
    error_default: router.Close,
  )
  let ctx = router.Context(registry:)

  let assert Ok(_) =
    router.handle_request(_, ctx)
    |> wisp_mist.handler(secret_key_base)
    |> wrap_reload()
    |> mist.new
    |> mist.port(8000)
    |> mist.start
}
