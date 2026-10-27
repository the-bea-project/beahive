-- src/beahive/sql/list_clients.sql

SELECT
    username,
    -- password_hash,
    can_read,
    can_write,
    can_delete,
    enabled
FROM clients
ORDER BY username