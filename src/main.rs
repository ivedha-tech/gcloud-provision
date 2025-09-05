use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::{Command, Output},
    sync::Arc,
};
use tokio::sync::Mutex;
use tokio::time::{timeout, Duration};
use uuid::Uuid;

#[derive(Deserialize)]
struct ScriptExecutionPayload {
    script_path: String,
    #[serde(default)]
    args: Vec<String>,
}

#[derive(Clone)]
struct AppState {
    logs: Arc<Mutex<HashMap<String, JobLog>>>,
    allowed_script_dir: PathBuf,
}

#[derive(Serialize, Clone)]
struct JobLog {
    status: JobStatus,
    stdout: String,
    stderr: String,
    exit_code: Option<i32>,
    error_message: Option<String>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "lowercase")]
enum JobStatus {
    Running,
    Completed,
    Failed,
    TimedOut,
}

#[derive(Serialize)]
struct ProvisionResponse {
    job_id: String,
    status: JobStatus,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            logs: Arc::new(Mutex::new(HashMap::new())),
            // Only allow scripts from a specific directory
            allowed_script_dir: PathBuf::from("./allowed_scripts"),
        }
    }
}

impl Default for JobLog {
    fn default() -> Self {
        Self {
            status: JobStatus::Running,
            stdout: String::new(),
            stderr: String::new(),
            exit_code: None,
            error_message: None,
        }
    }
}

fn validate_script_path(script_path: &str, allowed_dir: &PathBuf) -> Result<PathBuf, String> {
    // Prevent path traversal attacks
    if script_path.contains("..") || script_path.starts_with('/') {
        return Err("Invalid script path: path traversal detected".to_string());
    }

    let full_path = allowed_dir.join(script_path);

    // Ensure the path is within the allowed directory
    if !full_path.starts_with(allowed_dir) {
        return Err("Script path outside allowed directory".to_string());
    }

    // Check if file exists and is executable
    if !full_path.exists() {
        return Err("Script file does not exist".to_string());
    }

    // Check if it's a regular file
    if !full_path.is_file() {
        return Err("Path is not a regular file".to_string());
    }

    // Check permissions (Unix only)
    #[cfg(unix)]
    {
        let metadata =
            fs::metadata(&full_path).map_err(|e| format!("Failed to read file metadata: {}", e))?;
        let permissions = metadata.permissions();
        if permissions.mode() & 0o111 == 0 {
            return Err("Script is not executable".to_string());
        }
    }

    Ok(full_path)
}

fn scan_script_for_dangerous_patterns(script_content: &str) -> Result<(), String> {
    let dangerous_patterns = vec![
        ("rm -rf /", "Dangerous recursive delete"),
        ("rm -rf /*", "Dangerous recursive delete"),
        (":(){:|:&};:", "Fork bomb detected"),
        ("curl.*\\|.*sh", "Piped execution from web"),
        ("wget.*\\|.*sh", "Piped execution from web"),
        ("dd if=/dev/", "Direct disk access"),
        ("mkfs", "Filesystem creation"),
        ("fdisk", "Disk partitioning"),
        ("format", "Disk formatting"),
        ("/etc/passwd", "Access to password file"),
        ("sudo", "Privilege escalation"),
        ("su ", "User switching"),
        ("chmod 777", "Dangerous permission change"),
        ("chown", "Ownership change"),
    ];

    for (pattern, description) in dangerous_patterns {
        if script_content.contains(pattern) {
            return Err(format!(
                "Blocked dangerous pattern: {} ({})",
                pattern, description
            ));
        }
    }
    Ok(())
}

async fn validate_script(script_path: &PathBuf) -> Result<(), String> {
    // Read and validate script content
    let script_content =
        fs::read_to_string(script_path).map_err(|e| format!("Failed to read script: {}", e))?;

    scan_script_for_dangerous_patterns(&script_content)?;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Create the allowed scripts directory if it doesn't exist
    let allowed_dir = PathBuf::from("./allowed_scripts");
    fs::create_dir_all(&allowed_dir)?;

    let state = AppState {
        allowed_script_dir: allowed_dir,
        ..Default::default()
    };

    let app = Router::new()
        .route("/provision", post(provision))
        .route("/logs/:job_id", get(get_logs))
        .route("/health", get(health_check))
        .with_state(state);

    let port = std::env::var("PORT").unwrap_or_else(|_| "8080".to_string());
    let addr = format!("0.0.0.0:{}", port);
    println!("Listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
}

async fn provision(
    State(state): State<AppState>,
    Json(payload): Json<ScriptExecutionPayload>,
) -> Result<Json<ProvisionResponse>, (StatusCode, String)> {
    // Validate script path
    let script_path = match validate_script_path(&payload.script_path, &state.allowed_script_dir) {
        Ok(path) => path,
        Err(e) => return Err((StatusCode::BAD_REQUEST, e)),
    };

    // Validate script content
    if let Err(e) = validate_script(&script_path).await {
        return Err((StatusCode::BAD_REQUEST, e));
    }

    let job_id = Uuid::new_v4().to_string();

    // Initialize job log
    {
        let mut logs = state.logs.lock().await;
        logs.insert(job_id.clone(), JobLog::default());
    }

    let state_clone = state.clone();
    let job_id_clone = job_id.clone();
    let args = payload.args;

    tokio::spawn(async move {
        let mut job_log = JobLog::default();

        // Build command with arguments
        let mut cmd = Command::new("bash");
        cmd.arg(&script_path);
        for arg in &args {
            // Basic validation of arguments
            if arg.contains("..") || arg.contains(';') || arg.contains('|') {
                job_log.status = JobStatus::Failed;
                job_log.error_message = Some("Invalid argument detected".to_string());
                state_clone.logs.lock().await.insert(job_id_clone, job_log);
                return;
            }
            cmd.arg(arg);
        }

        // Use spawn_blocking to run the synchronous command in a blocking thread pool
        let cmd_future = tokio::task::spawn_blocking(move || cmd.output());

        match timeout(Duration::from_secs(300), cmd_future).await {
            Ok(Ok(Ok(output))) => {
                job_log.status = if output.status.success() {
                    JobStatus::Completed
                } else {
                    JobStatus::Failed
                };
                job_log.stdout = String::from_utf8_lossy(&output.stdout).to_string();
                job_log.stderr = String::from_utf8_lossy(&output.stderr).to_string();
                job_log.exit_code = output.status.code();
            }
            Ok(Ok(Err(e))) => {
                job_log.status = JobStatus::Failed;
                job_log.error_message = Some(format!("Failed to execute script: {}", e));
            }
            Ok(Err(_)) => {
                job_log.status = JobStatus::Failed;
                job_log.error_message = Some("Failed to spawn blocking task".to_string());
            }
            Err(_) => {
                job_log.status = JobStatus::TimedOut;
                job_log.error_message =
                    Some("Script execution timed out after 5 minutes".to_string());
            }
        }

        state_clone.logs.lock().await.insert(job_id_clone, job_log);
    });

    Ok(Json(ProvisionResponse {
        job_id,
        status: JobStatus::Running,
    }))
}

async fn get_logs(
    State(state): State<AppState>,
    Path(job_id): Path<String>,
) -> Result<Json<JobLog>, (StatusCode, String)> {
    // Validate job_id format
    if Uuid::parse_str(&job_id).is_err() {
        return Err((StatusCode::BAD_REQUEST, "Invalid job ID format".to_string()));
    }

    let logs = state.logs.lock().await;
    if let Some(log) = logs.get(&job_id) {
        Ok(Json(log.clone()))
    } else {
        Err((StatusCode::NOT_FOUND, "Job not found".to_string()))
    }
}

async fn health_check() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "healthy",
        "timestamp": chrono::Utc::now().to_rfc3339()
    }))
}
