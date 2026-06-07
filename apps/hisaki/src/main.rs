use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    middleware::{self, Next},
    response::IntoResponse,
    routing::post,
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{env, sync::Arc};
use tokio::net::TcpListener;
use tower_http::trace::TraceLayer;
use tracing::info;

#[derive(Clone)]
struct AppState {
    api_token: String,
    discord_webhook_url: String,
    http: reqwest::Client,
}

#[derive(Deserialize)]
struct Event {
    event: Option<String>,
    request: Option<String>,
    lat: Option<f64>,
    lng: Option<f64>,
    address: Option<String>,
    station: Option<String>,
    station_dist: Option<u32>,
    user_agent: Option<String>,
    ip: Option<String>,
    timestamp: Option<String>,
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
        api_token: env::var("HS_API_TOKEN").expect("HS_API_TOKEN not set"),
        discord_webhook_url: env::var("DISCORD_WEBHOOK_URL")
            .expect("DISCORD_WEBHOOK_URL not set"),
        http: reqwest::Client::new(),
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
    let embed = build_embed(&ev, event_name);

    let _ = state
        .http
        .post(&state.discord_webhook_url)
        .json(&json!({ "embeds": [embed] }))
        .send()
        .await;

    info!(event = event_name, "forwarded to Discord");
    Json(json!({ "ok": true }))
}

fn build_embed(ev: &Event, event_name: &str) -> Value {
    let (title, color) = match event_name {
        "page_opened" => ("📱 サイトを開いた", 0x9b59b6u32),
        "auth_success" => ("✅ 認証成功", 0x2ecc71),
        "auth_failure" => ("❌ 認証失敗", 0xe74c3c),
        "survey" => match ev.request.as_deref() {
            Some("line") => ("💬 LINEしてほしい", 0xe8729a),
            Some("call") => ("📞 電話してほしい", 0xe8729a),
            Some("come") => ("🚗 駆けつけてほしい", 0xe74c3c),
            _ => ("📋 アンケート送信", 0xe8729a),
        },
        _ => ("📌 イベント", 0x95a5a6),
    };

    let mut fields: Vec<Value> = vec![];

    if let Some(ts) = &ev.timestamp {
        fields.push(json!({ "name": "時刻", "value": ts, "inline": true }));
    }
    if let Some(ip) = &ev.ip {
        fields.push(json!({ "name": "IP", "value": ip, "inline": true }));
    }
    if let Some(ua) = &ev.user_agent {
        let short_ua = ua.chars().take(80).collect::<String>();
        fields.push(json!({ "name": "UA", "value": short_ua, "inline": false }));
    }
    if let Some(station) = &ev.station {
        let dist_str = ev.station_dist
            .map(|d| format!(" の近く（約 {}m）", d))
            .unwrap_or_default();
        fields.push(json!({ "name": "最寄り駅", "value": format!("{}駅{}", station, dist_str), "inline": false }));
    } else if let Some(address) = &ev.address {
        fields.push(json!({ "name": "場所", "value": address, "inline": false }));
    }
    if let (Some(lat), Some(lng)) = (ev.lat, ev.lng) {
        fields.push(json!({
            "name": "地図",
            "value": format!("[Google Maps で見る](https://maps.google.com/?q={},{})", lat, lng),
            "inline": false
        }));
    }

    json!({
        "title": title,
        "color": color,
        "fields": fields,
    })
}
