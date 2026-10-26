-- src/beahive/sql/get_client.sql

SELECT
    username,
    password_hash,
    can_read,
    can_write,
    can_delete,
    enabled
FROM clients
WHERE username = @username
LIMIT 1;