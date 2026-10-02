mod auth;
mod domain;

use auth::Viewer;
use axum::{
    Json, Router,
    body::Bytes,
    extract::{DefaultBodyLimit, Path, RawQuery, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    serve::ListenerExt,
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use domain::{MAX_ID, positive_integer};
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use std::{
    cell::RefCell,
    env,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

#[global_allocator]
static ALLOCATOR: mimalloc::MiMalloc = mimalloc::MiMalloc;
const PRAGMAS: &str = "PRAGMA busy_timeout = 5000; PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA cache_size = -16000; PRAGMA temp_store = MEMORY;";

#[derive(Clone)]
struct AppState {
    secret: Arc<[u8]>,
    db_path: Arc<str>,
    writer: Arc<Mutex<Connection>>,
    sqlite: Arc<str>,
}

struct ApiError(StatusCode, &'static str);
impl ApiError {
    fn bad(message: &'static str) -> Self {
        Self(StatusCode::BAD_REQUEST, message)
    }
    fn unauthorized() -> Self {
        Self(StatusCode::UNAUTHORIZED, "unauthorized")
    }
    fn not_found() -> Self {
        Self(StatusCode::NOT_FOUND, "not found")
    }
    fn internal() -> Self {
        Self(StatusCode::INTERNAL_SERVER_ERROR, "internal")
    }
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        #[derive(Serialize)]
        struct ErrorBody {
            error: &'static str,
        }
        (self.0, Json(ErrorBody { error: self.1 })).into_response()
    }
}
impl From<rusqlite::Error> for ApiError {
    fn from(error: rusqlite::Error) -> Self {
        eprintln!("SQLite error: {error}");
        Self::internal()
    }
}
fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock before Unix epoch")
        .as_millis() as u64
}

/// Derived structs also accept JSON arrays, so this requires the object the contract specifies.
fn json_object<'a, T: Deserialize<'a>>(json: &'a [u8]) -> Option<T> {
    if !json.trim_ascii_start().starts_with(b"{") {
        return None;
    }
    serde_json::from_slice(json).ok()
}

thread_local! {
    static READER: RefCell<Option<Connection>> = const { RefCell::new(None) };
}

fn open_connection(path: &str) -> rusqlite::Result<Connection> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    connection.execute_batch(PRAGMAS)?;
    Ok(connection)
}

impl AppState {
    fn read<T>(
        &self,
        operation: impl FnOnce(&Connection) -> Result<T, ApiError>,
    ) -> Result<T, ApiError> {
        // Reads take 10–30µs, well within Tokio's blocking-between-awaits guidance, like Go/Bun's synchronous SQLite calls.
        READER.with_borrow_mut(|reader| {
            let connection = match reader {
                Some(connection) => connection,
                None => reader.insert(open_connection(&self.db_path)?),
            };
            operation(connection)
        })
    }
}

async fn feed(
    State(state): State<AppState>,
    viewer: Viewer,
    RawQuery(query): RawQuery,
) -> Result<Json<domain::Feed>, ApiError> {
    let mut query = form_urlencoded::parse(query.as_deref().unwrap_or("").as_bytes());
    let limit = query
        .clone()
        .find(|(key, _)| key == "limit")
        .map(|(_, value)| {
            positive_integer(&value, 50).ok_or_else(|| ApiError::bad("invalid limit"))
        })
        .transpose()?
        .unwrap_or(20);
    let cursor = match query.find(|(key, _)| key == "cursor") {
        None => (MAX_ID, MAX_ID),
        Some((_, encoded)) => {
            let decoded = URL_SAFE_NO_PAD
                .decode(encoded.as_bytes())
                .map_err(|_| ApiError::bad("invalid cursor"))?;
            let decoded =
                std::str::from_utf8(&decoded).map_err(|_| ApiError::bad("invalid cursor"))?;
            let (time, id) = decoded
                .split_once(':')
                .ok_or_else(|| ApiError::bad("invalid cursor"))?;
            (
                positive_integer(time, MAX_ID).ok_or_else(|| ApiError::bad("invalid cursor"))?,
                positive_integer(id, MAX_ID).ok_or_else(|| ApiError::bad("invalid cursor"))?,
            )
        }
    };
    state
        .read(move |connection| domain::feed(connection, viewer, limit, cursor))
        .map(Json)
}
async fn detail(
    State(state): State<AppState>,
    _viewer: Viewer,
    Path(id): Path<String>,
) -> Result<Json<domain::Detail>, ApiError> {
    let id = positive_integer(&id, MAX_ID).ok_or_else(|| ApiError::bad("invalid id"))?;
    state
        .read(move |connection| domain::detail(connection, id))
        .map(Json)
}
async fn create(
    State(state): State<AppState>,
    viewer: Viewer,
    Path(id): Path<String>,
    body: Result<Bytes, axum::extract::rejection::BytesRejection>,
) -> Result<(StatusCode, Json<domain::CreatedComment>), ApiError> {
    let id = positive_integer(&id, MAX_ID).ok_or_else(|| ApiError::bad("invalid id"))?;
    let bytes = body.map_err(|error| {
        if error.status() == StatusCode::PAYLOAD_TOO_LARGE {
            ApiError(StatusCode::PAYLOAD_TOO_LARGE, "invalid body")
        } else {
            ApiError::bad("invalid body")
        }
    })?;
    let body = parse_body(&bytes)?;
    let length = body.encode_utf16().count();
    if !(1..=2000).contains(&length) {
        return Err(ApiError::bad("invalid body"));
    }
    let comment = tokio::task::spawn_blocking(move || {
        let mut writer = state.writer.lock().map_err(|_| ApiError::internal())?;
        domain::create(&mut writer, id, body, viewer)
    })
    .await
    .map_err(|_| ApiError::internal())??;
    Ok((StatusCode::CREATED, Json(comment)))
}
fn parse_body(bytes: &[u8]) -> Result<String, ApiError> {
    #[derive(Deserialize)]
    struct CommentInput {
        body: String,
    }
    json_object::<CommentInput>(bytes)
        .map(|input| input.body)
        .ok_or_else(|| ApiError::bad("invalid body"))
}

async fn meta(State(state): State<AppState>) -> Json<Meta> {
    Json(Meta {
        runtime: concat!("rust ", env!("RUST_VERSION")),
        framework: concat!("axum ", env!("AXUM_VERSION")),
        sqlite: state.sqlite.to_string(),
    })
}
#[derive(Serialize)]
struct Meta {
    runtime: &'static str,
    framework: &'static str,
    sqlite: String,
}

async fn shutdown() {
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("install SIGTERM handler");
    tokio::select! { result = tokio::signal::ctrl_c() => { result.expect("install SIGINT handler"); }, _ = terminate.recv() => {} }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = env::var("DB_PATH")?;
    if !std::fs::metadata(&path)?.is_file() {
        return Err("DB_PATH is not a file".into());
    }
    let secret = env::var("JWT_SECRET")?;
    if secret.is_empty() {
        return Err("JWT_SECRET is empty".into());
    }
    let writer = open_connection(&path)?;
    let sqlite: String = writer.query_row("SELECT sqlite_version()", [], |row| row.get(0))?;
    let state = AppState {
        secret: secret.into_bytes().into(),
        db_path: path.into(),
        writer: Arc::new(Mutex::new(writer)),
        sqlite: sqlite.into(),
    };
    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/meta", get(meta))
        .route("/feed", get(feed))
        .route("/posts/{id}", get(detail))
        .route("/posts/{id}/comments", post(create))
        .fallback(|| async { ApiError::not_found() })
        .layer(DefaultBodyLimit::max(64 * 1024))
        .with_state(state);
    let port = env::var("PORT")
        .unwrap_or_else(|_| "3000".into())
        .parse::<u16>()?;
    // axum leaves Nagle on; Go, Node and Bun all disable it, and Nagle stalls multi-segment responses.
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port))
        .await?
        .tap_io(|tcp| {
            if let Err(error) = tcp.set_nodelay(true) {
                eprintln!("failed to set TCP_NODELAY: {error}");
            }
        });
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown())
        .await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::parse_body;

    #[test]
    fn comment_body_requires_an_object_with_a_string() {
        for body in [
            r#"["ok"]"#,
            r#"[]"#,
            r#""ok""#,
            r#"null"#,
            r#"{}"#,
            r#"{"body":1}"#,
        ] {
            assert!(parse_body(body.as_bytes()).is_err(), "{body}");
        }
        assert_eq!(
            parse_body(br#"{"body":"ok","extra":true}"#).ok().as_deref(),
            Some("ok")
        );
    }
}
