use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    middleware::{self, Next},
    response::IntoResponse,
    routing::post,
    Json, Router,
};
use serde::Deserialize;
use serde_json::json;
use std::{env, sync::Arc};
use tokio::net::TcpListener;
use tokio::process::Command;
use tower_http::trace::TraceLayer;
use tracing::info;

#[derive(Clone)]
struct AppState {
    api_token:         String,
    discord_cli:       String,   // discord_cli バイナリのパス
    discord_token:     String,   // DISCORD_TOKEN
    discord_channel:   u64,      // DISCORD_CHANNEL_ID
}

#[derive(Deserialize)]
struct Event {
    event:        Option<String>,
    request:      Option<String>,
    lat:          Option<f64>,
    lng:          Option<f64>,
    address:      Option<String>,
    station:      Option<String>,
    station_dist: Option<u32>,
    #[allow(dead_code)]
    user_agent:   Option<String>,
    ip:           Option<String>,
    timestamp:    Option<String>,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_env("RUST_LOG")
                .add_directive("hisaki=info".parse().unwrap()),
        )
        .init();

    let state = Arc::new(AppState {
        api_token:       env::var("HS_API_TOKEN").expect("HS_API_TOKEN not set"),
        discord_cli:     env::var("DISCORD_CLI").unwrap_or_else(|_| "discord_cli".to_string()),
        discord_token:   env::var("DISCORD_TOKEN").expect("DISCORD_TOKEN not set"),
        discord_channel: env::var("DISCORD_CHANNEL_ID")
            .expect("DISCORD_CHANNEL_ID not set")
            .parse()
            .expect("DISCORD_CHANNEL_ID must be a number"),
    });

    let app = Router::new()
        .route("/api/event", post(handle_event))
        .route_layer(middleware::from_fn_with_state(state.clone(), auth_middleware))
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let port = env::var("PORT").unwrap_or_else(|_| "3001".to_string());
    let addr = format!("0.0.0.0:{port}");
    let listener = TcpListener::bind(&addr).await.unwrap();
    info!("listening on {addr}");
    axum::serve(listener, app).await.unwrap();
}

async fn auth_middleware(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    req: axum::extract::Request,
    next: Next,
) -> impl IntoResponse {
    let token = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));

    match token {
        Some(t) if t == state.api_token => next.run(req).await,
        _ => (StatusCode::UNAUTHORIZED, "Unauthorized").into_response(),
    }
}

async fn handle_event(
    State(state): State<Arc<AppState>>,
    Json(ev): Json<Event>,
) -> impl IntoResponse {
    let event_name = ev.event.as_deref().unwrap_or("unknown");
    let message = build_message(&ev, event_name);

    let _ = Command::new(&state.discord_cli)
        .args(["send", "--channel", &state.discord_channel.to_string(), "--message", &message])
        .env("DISCORD_TOKEN", &state.discord_token)
        .spawn();

    info!(event = event_name, "forwarded to Discord");
    Json(json!({ "ok": true }))
}

fn build_message(ev: &Event, event_name: &str) -> String {
    let header = match event_name {
        "page_opened"  => "📱 サイトを開いた".to_string(),
        "auth_success" => "✅ 認証成功".to_string(),
        "auth_failure" => "❌ 認証失敗".to_string(),
        "survey" => match ev.request.as_deref() {
            Some("line") => "💬 LINEしてほしい".to_string(),
            Some("call") => "📞 電話してほしい".to_string(),
            Some("come") => "🚗 駆けつけてほしい".to_string(),
            _            => "📋 アンケート送信".to_string(),
        },
        _ => "📌 イベント".to_string(),
    };

    let mut lines = vec![header];

    if let Some(ts) = &ev.timestamp {
        lines.push(format!("🕐 {ts}"));
    }
    if let Some(station) = &ev.station {
        let dist = ev.station_dist
            .map(|d| format!("（約{d}m）"))
            .unwrap_or_default();
        lines.push(format!("📍 {station}駅の近く{dist}"));
    } else if let Some(addr) = &ev.address {
        lines.push(format!("📍 {addr}"));
    }
    if let (Some(lat), Some(lng)) = (ev.lat, ev.lng) {
        lines.push(format!("🗺️ https://maps.google.com/?q={lat},{lng}"));
    }
    if let Some(ip) = &ev.ip {
        lines.push(format!("🌐 {ip}"));
    }

    lines.join("\n")
}
