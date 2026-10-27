# Beahive

Beahive is a content-addressed HTTP storage service, written in
[Bea](https://github.com/the-bea-project/bea): a language that transpiles to
Gleam and runs on the Erlang VM (BEAM).

The design is a single, global store. Several clients authenticate against
it, and each has global permissions: `Read`, `Write` and `Delete`, which
apply to the whole store. An administrator manages the clients.

**Status.** The authentication and client-management layer is in place:
administrator and client logins with JWTs, client registration with
Argon2id-hashed passwords, rate limiting, and SQLite persistence through
Marmot-generated queries. Storage itself — uploading, addressing and
serving content — is not implemented yet. See [Project status](#project-status).

## Contents

- [Architecture](#architecture)
- [Authentication](#authentication)
- [HTTP API](#http-api)
- [Bea language features used in Beahive](#bea-language-features-used-in-beahive)
- [How Bea works with Gleam](#how-bea-works-with-gleam)
- [Using Marmot from Bea](#using-marmot-from-bea)
- [Running Beahive](#running-beahive)
- [Project status](#project-status)

## Architecture

All application code lives in one namespace, `beahive/`, with shared
definitions in a few root modules and the operations in shallow feature
modules.

```text
src/
├── beahive.bea                  entry point: config, database, HTTP server
├── beahive/
│   ├── config.bea               configuration from the environment (.env)
│   ├── context.bea              what every handler gets: config, database, rate-limit cache
│   ├── types.bea                shared types: permissions, roles, identities, JWT payload, request bodies
│   ├── errors.bea               application errors: ClientError, ValidationError
│   ├── responses.bea            the JSON response envelope, API response models and encoders
│   ├── validation.bea           request validation (registration)
│   ├── router.bea               global router: rate limiting, `/`, `/api/v1/…`
│   ├── middleware.bea           global middleware: per-address rate limiting
│   ├── auth/
│   │   ├── admin.bea            administrator login
│   │   ├── client.bea           client login (Argon2id verification)
│   │   ├── jwt.bea              JWT generation and verification
│   │   ├── headers.bea          bearer-token extraction
│   │   ├── middleware.bea       authorization: administrator-only routes
│   │   └── router.bea           /api/v1/auth/…
│   ├── client/
│   │   ├── manager.bea          client registration, lookup and listing (SQLite)
│   │   └── router.bea           /api/v1/client/…
│   ├── security/
│   │   ├── client_ip.bea        the client's address (and when to trust X-Forwarded-For)
│   │   └── rate_limiters.bea    the rate-limit decision
│   ├── services/
│   │   └── cache.bea            the rate-limit cache, an ETS table (rasa)
│   ├── runtime/
│   │   ├── runtime.gleam        Erlang FFI bindings
│   │   └── beahive_ffi.erl      app version, IP address parsing
│   └── sql/                     SQL queries, compiled by Marmot
├── bea_json/                    JSON derivers for @derive(decoder) and @derive(encoder)
└── generated/sql/               Marmot's generated Gleam (do not edit)

db/migrations/                   SQLite migrations
_bruno_beahive/                  a Bruno collection of the API's requests
```

A request goes through:

```text
HTTP request
    ↓
ewe (HTTP server)                          beahive.bea
    ↓
global middleware: rate limiting           router.bea → middleware.bea
    ↓                                      (429 when over the limit)
routing: /, /api/v1/auth, /api/v1/client   router.bea, auth/router.bea, client/router.bea
    ↓
authorization: administrator token         auth/middleware.bea (client routes only)
    ↓
body: read (≤ 4 KB), decode, validate      types.bea decoders, validation.bea
    ↓
application logic                          auth/admin.bea, auth/client.bea, client/manager.bea
    ↓
SQLite, through Marmot's queries           generated/sql/beahive_sql.gleam
    ↓
JSON response                              responses.bea
```

Every response, errors included, has the same JSON envelope:

```json
{"status": 201, "message": "Created!", "data": null}
```

`status` repeats the HTTP status code, and `data` is `null` or an object.

### Rate limiting

Every request is counted against its client address before routing: an
IPv4 address, or the /64 network of an IPv6 address. The counts live in an
in-memory ETS table. Past `IP_RATE_LIMIT_ATTEMPTS` requests, the address
gets `429` until `IP_RATE_LIMIT_WINDOW_SECS` have passed since its last
allowed request, when its count starts over. Entries expire
`IP_RATE_TTL_SECS` after the last allowed request.

`X-Forwarded-For` is only trusted when the connection comes from the same
machine (a reverse proxy on loopback or a Unix socket), and then only its
last entry, the one the proxy added.

## Authentication

There are two roles, defined in `beahive/types.bea`:

- **Administrator.** One account, configured with `ADMIN_USERNAME` and
  `ADMIN_PASSWORD`. It is not stored in the database. Only the administrator
  can manage clients.
- **Client.** Accounts stored in the `clients` table, each with global
  `Read`, `Write` and `Delete` permissions, stored as 0/1 flags, and an
  `enabled` flag.

**Passwords.** A client's password is hashed with Argon2id
([Argus](https://hex.pm/packages/argus)) when it is registered, with a
random salt. The table stores the encoded hash, which includes the salt and
the parameters, so a login is checked with `argus.verify(stored_hash,
password)` alone. A login fails when the client doesn't exist, the password
doesn't match, or the client is disabled.

**Tokens.** A successful login returns a JWT
([ywt](https://hex.pm/packages/ywt_core)), signed with HS256 using
`JWT_SECRET`. It carries:

- `sub`: `"admin"`, or the client's username;
- `role`: `"administrator"` or `"client"`;
- an expiry 15 minutes after issue, and `beahive` as issuer and audience.

The permissions are not in the token. Requests send it as
`Authorization: Bearer <token>`.

**Authorization.** The client-management routes require an administrator
token (`auth/middleware.admin_only`). Token verification only accepts
administrator tokens for now. Clients can log in and receive a token, but
no endpoint accepts client tokens yet: they are meant for the storage
endpoints.

## HTTP API

Request bodies are JSON, at most 4096 bytes (a larger body gets `413 Body
too large`). The examples assume the server on `localhost:8000`.

### `GET /`

The service's status.

```sh
curl localhost:8000/
```

```json
{"status":200,"message":"App root hit!","data":{"app":"beahive","version":"0.0.1","uptime_seconds":42.5}}
```

### `POST /api/v1/auth/admin`

Administrator login.

```sh
curl -X POST localhost:8000/api/v1/auth/admin \
  -H 'content-type: application/json' \
  -d '{"username": "admin", "password": "<ADMIN_PASSWORD>"}'
```

| Status | `message` | When |
| --- | --- | --- |
| 200 | `Logged in` | `data` is `{"Bearer Token": "<jwt>"}` |
| 400 | `Invalid LoginRequest: …` | the body isn't `{"username": …, "password": …}` |
| 401 | `Wrong username or password` | |
| 413 | `Body too large` | |

### `POST /api/v1/auth/client`

Client login, with the same body.

```sh
curl -X POST localhost:8000/api/v1/auth/client \
  -H 'content-type: application/json' \
  -d '{"username": "alice", "password": "alice-password-1"}'
```

| Status | `message` | When |
| --- | --- | --- |
| 200 | `Logged in` | `data` is `{"Bearer Token": "<jwt>"}` |
| 400 | `Invalid LoginRequest: …` | malformed body |
| 401 | `Client check failed` | `data.reason` is the error: `ClientNotFound`, `InvalidPassword`, `ClientDisabled`, `HashingFailed(…)` or `DatabaseFailed(…)` |
| 413 | `Body too large` | |

### `POST /api/v1/client/register`

Registers a client. Administrator only.

```sh
curl -X POST localhost:8000/api/v1/client/register \
  -H "authorization: Bearer $ADMIN_TOKEN" \
  -H 'content-type: application/json' \
  -d '{"username": "alice", "password": "alice-password-1", "permissions": ["read", "delete"]}'
```

`permissions` lists any of `"read"`, `"write"` and `"delete"`. A username
needs at least 3 characters, a password at least 12.

| Status | `message` | When |
| --- | --- | --- |
| 201 | `Created!` | `data` is `null` |
| 400 | `Request failed validation` | `data.reason`: `InvalidUsername(…)`, `PasswordTooShort(…)` or `InvalidPermission(…)` |
| 400 | `Failed to register client!` | for example a username that is taken: `DatabaseFailed(…)` |
| 401 | `Invalid RegisterRequest` | malformed body |
| 403 | `Auth middleware 403!` | missing, invalid or expired administrator token |
| 413 | `Body too large` | |

### `GET /api/v1/client/list`

Administrator only. Work in progress: the clients are queried, and printed
in the server's output, but the response doesn't include them yet.

```sh
curl localhost:8000/api/v1/client/list -H "authorization: Bearer $ADMIN_TOKEN"
```

| Status | `message` | When |
| --- | --- | --- |
| 201 | `Here's the client listing!` | `data` is `null` |
| 403 | `Auth middleware 403!` | missing, invalid or expired administrator token |

### Other responses

| Status | `message` | When |
| --- | --- | --- |
| 404 | `Global router 404!` | a path outside `/` and `/api/v1/…` |
| 404 | `V1 router 404!` | `/api/v1/…` other than `auth` and `client` |
| 404 | `Auth router 404!` | an unknown path or method under `/api/v1/auth/` or `/api/v1/client/` |
| 429 | `Global middleware 429!` | rate limited |

`_bruno_beahive/` has these requests as a [Bruno](https://www.usebruno.com/)
collection.

## Bea language features used in Beahive

Bea reads like Gleam with fewer layers: no `let`, multi-clause functions,
string interpolation, and several ways to leave a function early without
nesting. All of it compiles to ordinary Gleam.

### Early returns: `?` and `else` guards

**`?` propagates errors.** `expr?` is the value inside an `Ok`. On an
`Error`, the enclosing function returns that error. From
`auth/client.bea`:

```bea
client_row = manager.get_client(ctx, username)?
```

`get_client` returns `Result(Row, ClientError(…))`, so an unknown client or a
database error leaves `check` right there with that error.

**`? else` binds and maps the error.** With `else`, the error is bound to a
name and the function returns what follows. In `auth/client.bea`, Argus's
error becomes Beahive's:

```bea
valid = argus.verify(client_row.password_hash, password)?
  else e -> Error(errors.HashingFailed(e))
```

The fallback can be any value of the function's return type, a response
included. That is how each HTTP handler turns a failure into its error
response, step by step, in `auth/router.bea`:

```bea
req = ewe.read_body(req, limit: 4096)?
  else _ -> responses.send_resp_json(413, "Body too large", json.null())

LoginRequest(username:, password:) = json.parse_bits(
  req.body,
  LoginRequest.decoder(),
)?
  else e -> responses.send_resp_json(
    400,
    "Invalid LoginRequest: #{string.inspect(e)}",
    json.null(),
  )

token = admin.check(ctx, username, password)?
  else _ -> responses.send_resp_json(
    401,
    "Wrong username or password",
    json.null(),
  )

responses.send_resp_json(
  200,
  "Logged in",
  json.object([("Bearer Token", json.string(token))]),
)
```

**Boolean guards.** A condition followed by `else` must hold, or the
function returns the fallback. From `auth/client.bea`:

```bea
valid else Error(errors.InvalidPassword)
client_row.enabled == 1 else Error(errors.ClientDisabled)
```

and from `validation.bea`:

```bea
string.length(username) >= 3
  else Error(
    errors.InvalidUsername("username needs to have more than 2 characters"),
  )
```

**Pattern guards.** Any pattern works, with the same `else`. From
`middleware.bea`:

```bea
Ok(ip) = client_ip.client_ip(req) else False
```

**Guards are not `if … else`.** A guard's `else` *returns from the
function*: the rest of the function never runs. An `if … else` is an
expression with a value, and the function carries on. `auth/admin.bea` uses
the expression:

```bea
if valid_username and valid_password {
  admin = types.Authenticated(subject: "admin", role: types.Administrator)
  jwt.generate(admin, ctx.config.jwt_secret)
  |> Ok
} else {
  Error(Nil)
}
```

Guards keep each check on its own line, top to bottom, with no nesting and
no callbacks. The generated Gleam is the nested `case` expressions you would
otherwise write.

### Typed errors

Failures are custom types in `beahive/errors.bea`, so a function's type says
what can go wrong:

```bea
pub type ClientError(hash_error, db_error) {
  HashingFailed(hash_error)
  DatabaseFailed(db_error)
  ClientNotFound
  InvalidPassword
  ClientDisabled
}
```

`auth/client.check` returns `Result(String, errors.ClientError(argus.HashError,
sqlight.Error))`: a token, or one of those reasons.

### Immutable bindings

Bindings never change. Writing the same name again makes a new binding that
shadows the old one. `auth/client.bea` builds a list of permissions that way:

```bea
acc = []

acc = if can_read == 1 {
  [types.Read | acc]
} else {
  acc
}
```

Each `acc` is a new list; nothing is mutated.

### Multi-clause functions

A function can be written as clauses, one per input. From
`client/manager.bea`:

```bea
def bool_to_int(value: Bool) -> Int

def bool_to_int(False) {
  0
}

def bool_to_int(True) {
  1
}
```

### Derived JSON decoders and encoders

`@derive` writes a record's decoder or encoder from its fields. The derived
functions come from ordinary libraries in this repository,
`src/bea_json/decoder.bea` and `src/bea_json/encoder.bea`, not from the
compiler. From `types.bea` and `responses.bea`:

```bea
import bea_json/decoder

@derive(decoder)
pub type LoginRequest {
  LoginRequest(username: String, password: String)
}
```

```bea
import bea_json/encoder

@derive(encoder)
pub type ClientListing {
  username: String,
  permissions: List(String),
  enabled: Bool,
}
```

`@derive(decoder)` on `LoginRequest` defines `login_request_decoder()`, a
standard `decode.Decoder`, which Bea code calls through the type:
`json.parse_bits(req.body, LoginRequest.decoder())`. `ClientListing` uses the
record form, `type T { field: Type, … }`, for a type with a single
constructor.

## How Bea works with Gleam

Bea compiles each `.bea` file to a Gleam module, and Gleam does the rest:
type checking, and compiling to Erlang. `bea build` writes the generated
Gleam project to `.beabuild/`. Gleam and Erlang files in `src/` are copied as
they are, which is how `runtime.gleam`, `beahive_ffi.erl` and Marmot's
generated modules sit next to the Bea code. Gleam's error messages are
rewritten to point at the `.bea` source.

Bea code uses Gleam packages directly, with no wrappers: ewe, sqlight, Argus,
ywt and rasa are ordinary Hex packages in `bea.toml`. `bea transpile
src/beahive/auth/client.bea` prints the Gleam a module becomes.

Gleam is a mature compiler and ecosystem. Bea is young: it is in beta, and
its tooling and documentation are much less established than Gleam's.

## Using Marmot from Bea

[Marmot](https://hex.pm/packages/marmot) generates typed Gleam functions
from SQL files, by checking each query against a SQLite database. The
workflow has five parts:

1. **Migrations**, `db/migrations/NNN_description.sql`, define the schema.
   `bea run -m marmot migrate` applies the ones not applied yet, and records
   them in a `schema_migrations` table.
2. **Queries**, one per file, in `src/beahive/sql/`.
3. **Code generation.** `bea run -m marmot` reads the queries, checks them
   against the database in `[tools.marmot]` (`beahive.sqlite`, in
   `bea.toml`), and writes Gleam.
4. **Generated modules.** The queries of `src/beahive/sql/` become
   `src/generated/sql/beahive_sql.gleam`, named after their directory, with a
   row type and a function per query. Don't edit it; regenerate it.
5. **Calling them from Bea.** Generated Gleam modules are imported like any
   other module.

For example, `src/beahive/sql/list_clients.sql`:

```sql
SELECT
    username,
    -- password_hash,
    can_read,
    can_write,
    can_delete,
    enabled
FROM clients
ORDER BY username
```

becomes this, in `beahive_sql.gleam`:

```gleam
pub type ListClientsRow {
  ListClientsRow(
    username: Option(String),
    can_read: Int,
    can_write: Int,
    can_delete: Int,
    enabled: Int,
  )
}

pub fn list_clients(
  db db: sqlight.Connection,
) -> Result(List(ListClientsRow), sqlight.Error)
```

and `client/manager.bea` calls it:

```bea
import generated/sql/beahive_sql

pub def list(ctx: context.Context) {
  beahive_sql.list_clients(db: ctx.db)
}
```

Named parameters (`@username`) become labelled arguments, and a query's
`Result(List(Row), sqlight.Error)` works with `?` and `else` like any other
`Result`:

```bea
rows = beahive_sql.get_client(
  db: ctx.db,
  username:
)? else e -> Error(errors.DatabaseFailed(e))
```

The commands:

```sh
bea run -m marmot migrate     # apply new migrations to beahive.sqlite
bea run -m marmot             # regenerate src/generated/sql/
bea run -m marmot help        # all commands and options
```

`--database PATH` points a command at another database file, e.g.
`bea run -m marmot migrate --database other.sqlite`.

> **Warning:** `bea run -m marmot reset` deletes the SQLite database and
> rebuilds it from the migrations. All local data, registered clients
> included, is lost. Copy `beahive.sqlite` before using it.

The generated types depend on the schema of the database they were
generated against, so regenerate after changing a migration or a query, and
commit the result. See [Project status](#project-status) for a known
difference between the migration and the committed bindings.

## Running Beahive

### Requirements

- [Bea](https://github.com/the-bea-project/bea/releases) 0.3.0 or newer
- [Gleam](https://gleam.run), with Erlang/OTP and rebar3
- A C compiler: Argus (Argon2) and SQLight's SQLite driver build native code

### Configuration

The configuration comes from the environment, with a `.env` file at the
project root loaded at startup. `env_template` lists the variables:

| Variable | Meaning |
| --- | --- |
| `HOST`, `PORT` | Where the server listens |
| `DB_PATH` | The SQLite database file. Keep it the same as `[tools.marmot].database` in `bea.toml` (`beahive.sqlite`) |
| `IP_RATE_LIMIT_ATTEMPTS` | Requests allowed per address before `429` |
| `IP_RATE_LIMIT_WINDOW_SECS` | Seconds after an address's last allowed request when its count starts over |
| `IP_RATE_TTL_SECS` | Seconds an address's entry is kept after its last allowed request |
| `ADMIN_USERNAME`, `ADMIN_PASSWORD` | The administrator's credentials |
| `JWT_SECRET` | The key tokens are signed with |

All of them are required: the server stops with `Missing config!` when one
is missing or a number doesn't parse.

```sh
cp env_template .env
openssl rand -hex 32          # put this in JWT_SECRET
```

Then set your own `ADMIN_PASSWORD` and `JWT_SECRET` in `.env`, and never
reuse the template's values. `.env` and the SQLite files are ignored by git.

### Database

```sh
bea run -m marmot migrate
```

creates `beahive.sqlite` with the `clients` table. Only regenerate the
query bindings (`bea run -m marmot`) after changing SQL.

### Server

```sh
bea run
```

starts the server on `HOST:PORT`. `bea check` type checks the project and
`bea build` builds it.

### Tests

There is no test suite yet: `bea test` reports that `test/beahive_test.gleam`
is missing. The `_bruno_beahive/` collection covers the API by hand.

## Project status

Implemented:

- administrator login, and client login with Argon2id password verification;
- JWT issue (15 minutes) and verification of administrator tokens;
- client registration with validation and global `Read`/`Write`/`Delete`
  permissions;
- rate limiting per client address;
- SQLite persistence through Marmot-generated queries.

In development:

- content-addressed storage: uploading, addressing and serving content, the
  service's purpose, which will use clients' tokens and permissions;
- `GET /api/v1/client/list` returning the clients (it queries them, but
  responds without them);
- accepting client tokens: `jwt.verify` only accepts administrator tokens.

Known issues:

- **Schema drift.** `db/migrations/001_client.sql` makes `username` the
  primary key, but the committed bindings were generated against a database
  with a separate `id` key and `username TEXT NOT NULL UNIQUE`. Regenerating
  against a database migrated from the current file changes
  `create_client`'s `username` to `Option(String)`, which
  `client/manager.bea` doesn't compile with. Settle the schema before
  regenerating.
- The registration validation's password message reads "username needs to
  have more than 11 characters"; it is about the password.
