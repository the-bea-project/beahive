import gleam/dynamic/decode
import sqlight

/// Generated from src/beahive/sql/create_client.sql
pub type CreateClientRow {
  CreateClientRow(
    username: String,
    can_read: Int,
    can_write: Int,
    can_delete: Int,
  )
}

/// Generated from src/beahive/sql/create_client.sql
pub fn create_client(
  db db: sqlight.Connection,
  username username: String,
  password_hash password_hash: String,
  can_read can_read: Int,
  can_write can_write: Int,
  can_delete can_delete: Int,
) -> Result(List(CreateClientRow), sqlight.Error) {
  sqlight.query(
    "INSERT INTO clients ( username, password_hash, can_read, can_write, can_delete ) VALUES ( @username, @password_hash, @can_read, @can_write, @can_delete ) RETURNING username, can_read, can_write, can_delete",
    on: db,
    with: [
      sqlight.text(username),
      sqlight.text(password_hash),
      sqlight.int(can_read),
      sqlight.int(can_write),
      sqlight.int(can_delete),
    ],
    expecting: {
      use username <- decode.field(0, decode.string)
      use can_read <- decode.field(1, decode.int)
      use can_write <- decode.field(2, decode.int)
      use can_delete <- decode.field(3, decode.int)
      decode.success(CreateClientRow(
        username:,
        can_read:,
        can_write:,
        can_delete:,
      ))
    },
  )
}
