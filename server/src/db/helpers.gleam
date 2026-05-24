import gleam/result
import sqlight

pub fn expect_one_record(
  records: Result(List(a), sqlight.Error),
  record_name: String,
) -> Result(a, sqlight.Error) {
  records
  |> result.map(fn(results) {
    case results {
      [] ->
        Error(sqlight.SqlightError(
          code: sqlight.Notfound,
          message: record_name <> " not found",
          offset: -1,
        ))
      [res] -> Ok(res)
      _ ->
        Error(sqlight.SqlightError(
          code: sqlight.Corrupt,
          message: "Multiple " <> record_name <> "s found",
          offset: -1,
        ))
    }
  })
  |> result.flatten
}
