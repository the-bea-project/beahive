-- src/beahive/sql/create_client.sql

INSERT INTO clients (
    username,
    password_hash,
    can_read,
    can_write,
    can_delete
)
VALUES (
    @username,
    @password_hash,
    @can_read,
    @can_write,
    @can_delete
)
RETURNING username, can_read, can_write, can_delete;