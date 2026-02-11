# AudioEnv System Architecture

## High-Level Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     AudioEnv macOS App                      │
│                      (SwiftUI + Swift)                      │
├─────────────────────────────────────────────────────────────┤
│  Views                Services              Models           │
│  • ContentView        • ScannerService      • AudioPlugin   │
│  • PluginBrowser      • BackupService       • AudioSession  │
│  • SessionBrowser     • PluginCatalog       • SessionProject│
│  • BackupConfigView   • ScanCacheStore      • ParsedProject │
│  • ProjectShareView   • *Parsers            • *ProjectTypes │
└────────────┬────────────────────────┬───────────────────────┘
             │                        │
             │ REST API               │ WebSocket (Real-time)
             │ (URLSession)           │
             ▼                        ▼
┌─────────────────────────────────────────────────────────────┐
│                   Backend API Layer                          │
│                  (FastAPI + Python)                         │
├─────────────────────────────────────────────────────────────┤
│  Endpoints                    WebSocket                      │
│  • /api/auth/*               • /api/ws/backup/{job_id}      │
│  • /api/plugins/*            • Real-time progress           │
│  • /api/projects/*                                          │
│  • /api/stats                                               │
└────────┬───────────────────┬──────────────────┬─────────────┘
         │                   │                  │
         │                   │                  │
         ▼                   ▼                  ▼
┌──────────────────┐  ┌──────────────┐  ┌─────────────────┐
│   PostgreSQL     │  │  AWS S3      │  │  Supabase Auth  │
│   (Database)     │  │  (Storage)   │  │  (OAuth/JWT)    │
├──────────────────┤  ├──────────────┤  ├─────────────────┤
│ • users          │  │ Bucket:      │  │ • User signup   │
│ • user_plugins   │  │ audioenv-    │  │ • Social login  │
│ • projects       │  │ backups/     │  │ • Token refresh │
│ • backup_jobs    │  │              │  │ • Password reset│
│ • share_tokens   │  │ Structure:   │  └─────────────────┘
└──────────────────┘  │ /users/      │
                      │   /{user_id}/│
                      │     /plugins/│
                      │     /sessions│
                      └──────────────┘
```

## Data Flow Diagrams

### 1. Plugin Backup Flow

```
┌─────────────┐
│   macOS     │
│   User      │
└──────┬──────┘
       │ 1. Click "Start Backup"
       ▼
┌─────────────────────────────────────┐
│ BackupConfigView                    │
│ • Runs PluginDeduplicator           │
│ • Shows savings preview             │
└──────┬──────────────────────────────┘
       │ 2. Prepare backup job
       ▼
┌─────────────────────────────────────┐
│ ScannerService                      │
│ .preparePluginsForBackup()          │
│ • Deduplicate by format (VST3)      │
│ • Calculate checksums               │
│ • Build plugin list                 │
└──────┬──────────────────────────────┘
       │ 3. POST /api/plugins/backup/initiate
       │    { plugins: [...] }
       ▼
┌─────────────────────────────────────┐
│ Backend: Create Backup Job          │
│ • Generate job_id                   │
│ • Check for existing plugins        │
│ • Generate presigned S3 URLs        │
│ • Return upload instructions        │
└──────┬──────────────────────────────┘
       │ 4. Return { job_id, upload_urls: [...] }
       ▼
┌─────────────────────────────────────┐
│ S3BackupDestination                 │
│ • Zip plugin bundles                │
│ • Multipart upload (50MB chunks)    │
│ • Report progress via WebSocket     │
└──────┬──────────────────────────────┘
       │ 5. WS: { type: "progress", uploaded_files: 15/120 }
       ▼
┌─────────────────────────────────────┐
│ BackupConfigView (UI Update)        │
│ • ProgressBar updates               │
│ • Show current file uploading       │
│ • Display upload speed              │
└──────┬──────────────────────────────┘
       │ 6. POST /api/plugins/backup/complete
       │    { job_id, uploaded: [...] }
       ▼
┌─────────────────────────────────────┐
│ Backend: Mark Job Complete          │
│ • Update job status                 │
│ • Save plugin metadata              │
│ • Send completion notification      │
└─────────────────────────────────────┘
```

### 2. Project Share & Compatibility Check Flow

```
┌─────────────┐
│  Producer A │
│  (macOS)    │
└──────┬──────┘
       │ 1. Open session in SessionDetailView
       ▼
┌─────────────────────────────────────┐
│ Click "Share Requirements"          │
└──────┬──────────────────────────────┘
       │ 2. Extract required plugins from parsed session
       ▼
┌─────────────────────────────────────┐
│ ProjectShareView                    │
│ • Lists required plugins            │
│ • Shows formats (VST3, AU, etc.)    │
└──────┬──────────────────────────────┘
       │ 3. POST /api/projects/share
       │    {
       │      name: "My Big Mix",
       │      format: "Ableton",
       │      required_plugins: [
       │        { name: "Serum", formats: ["VST3"], bundleID: "..." },
       │        ...
       │      ]
       │    }
       ▼
┌─────────────────────────────────────┐
│ Backend: Create Share Token         │
│ • Generate unique token (12 chars)  │
│ • Store in database with 7-day TTL  │
│ • Return share URL                  │
└──────┬──────────────────────────────┘
       │ 4. Return { share_url: "https://audioenv.app/check/abc123" }
       ▼
┌─────────────────────────────────────┐
│ Producer A copies/shares link       │
│ • Copy to clipboard                 │
│ • Send via Slack/Email/Discord      │
└─────────────────────────────────────┘
       │
       │ 5. Producer B opens link in browser
       ▼
┌─────────────────────────────────────┐
│  Producer B (Web Browser)           │
│  GET /check/abc123                  │
└──────┬──────────────────────────────┘
       │ 6. Backend fetches project info
       ▼
┌─────────────────────────────────────┐
│ PluginCompatibilityView (Web)      │
│ • Shows project name + DAW          │
│ • Lists all required plugins        │
│ • If logged in: compares against    │
│   Producer B's plugin collection    │
└──────┬──────────────────────────────┘
       │ 7. Compatibility result
       ▼
┌─────────────────────────────────────┐
│ Results Display                     │
│ ✅ Serum (VST3) - You have this     │
│ ✅ FabFilter Pro-Q 3 - You have this│
│ ❌ Omnisphere - Missing             │
│ ❌ Valhalla VintageVerb - Missing   │
│                                     │
│ Compatibility: 50%                  │
│ [Download Missing List] [Contact Producer A]
└─────────────────────────────────────┘
```

### 3. Authentication Flow

```
┌──────────────┐
│  macOS App   │
│  (First Run) │
└──────┬───────┘
       │ 1. User clicks "Sign In"
       ▼
┌─────────────────────────────────────┐
│ Show OAuth login sheet              │
│ (WKWebView or ASWebAuthSession)     │
└──────┬──────────────────────────────┘
       │ 2. Redirect to Supabase OAuth
       ▼
┌─────────────────────────────────────┐
│ Supabase Auth                       │
│ • Login with email/password         │
│ • Or: Sign in with Apple            │
│ • Or: Sign in with Google           │
└──────┬──────────────────────────────┘
       │ 3. Return: callback?code=xxx&state=yyy
       ▼
┌─────────────────────────────────────┐
│ macOS App: Exchange code for token │
│ POST /api/auth/token                │
│ { code: "xxx", state: "yyy" }       │
└──────┬──────────────────────────────┘
       │ 4. Backend validates with Supabase
       ▼
┌─────────────────────────────────────┐
│ Backend: Return JWT                 │
│ {                                   │
│   access_token: "eyJ...",           │
│   refresh_token: "...",             │
│   expires_in: 3600                  │
│ }                                   │
└──────┬──────────────────────────────┘
       │ 5. Store in macOS Keychain
       ▼
┌─────────────────────────────────────┐
│ Keychain.set(                       │
│   service: "com.audioenv.app",      │
│   account: user_id,                 │
│   value: access_token               │
│ )                                   │
└──────┬──────────────────────────────┘
       │ 6. All future API calls include:
       │    Authorization: Bearer eyJ...
       ▼
┌─────────────────────────────────────┐
│ Backend validates JWT on each req   │
│ • Verify signature                  │
│ • Check expiration                  │
│ • Extract user_id from claims       │
└─────────────────────────────────────┘
```

## Database Schema (PostgreSQL)

```sql
-- Users table (managed by Supabase Auth)
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    username VARCHAR(50) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT NOW(),
    last_login TIMESTAMP,
    subscription_tier VARCHAR(20) DEFAULT 'free', -- free, pro, unlimited
    storage_used_bytes BIGINT DEFAULT 0
);

-- User plugins (synced from macOS app)
CREATE TABLE user_plugins (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    plugin_name VARCHAR(255) NOT NULL,
    plugin_format VARCHAR(10) NOT NULL, -- AU, VST, VST3, AAX
    bundle_id VARCHAR(255),
    version VARCHAR(50),
    manufacturer VARCHAR(255),
    s3_key VARCHAR(512), -- Path in S3 bucket (if backed up)
    file_size_bytes BIGINT,
    checksum VARCHAR(64), -- SHA-256 for deduplication
    uploaded_at TIMESTAMP DEFAULT NOW(),
    last_verified TIMESTAMP,
    UNIQUE(user_id, bundle_id, plugin_format)
);

CREATE INDEX idx_user_plugins_user_id ON user_plugins(user_id);
CREATE INDEX idx_user_plugins_bundle_id ON user_plugins(bundle_id);

-- Shared projects (for compatibility checking)
CREATE TABLE projects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    format VARCHAR(20) NOT NULL, -- Ableton, Logic, ProTools
    required_plugins JSONB NOT NULL, -- Array of { name, formats, bundleID }
    share_token VARCHAR(64) UNIQUE NOT NULL,
    view_count INT DEFAULT 0,
    created_at TIMESTAMP DEFAULT NOW(),
    expires_at TIMESTAMP NOT NULL,
    is_public BOOLEAN DEFAULT true
);

CREATE INDEX idx_projects_share_token ON projects(share_token);
CREATE INDEX idx_projects_user_id ON projects(user_id);

-- Backup jobs (for tracking upload progress)
CREATE TABLE backup_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    job_type VARCHAR(20) NOT NULL, -- 'plugins', 'session'
    status VARCHAR(20) NOT NULL, -- 'pending', 'uploading', 'completed', 'failed'
    total_files INT NOT NULL,
    uploaded_files INT DEFAULT 0,
    total_bytes BIGINT NOT NULL,
    uploaded_bytes BIGINT DEFAULT 0,
    error_message TEXT,
    created_at TIMESTAMP DEFAULT NOW(),
    completed_at TIMESTAMP
);

CREATE INDEX idx_backup_jobs_user_id ON backup_jobs(user_id);
CREATE INDEX idx_backup_jobs_status ON backup_jobs(status);

-- Plugin catalog (for enriching user data)
CREATE TABLE plugin_catalog (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    manufacturer VARCHAR(255),
    bundle_ids JSONB, -- { "VST3": "com.example.plugin", "AU": "..." }
    aliases TEXT[], -- Alternative names
    image_url VARCHAR(512),
    category VARCHAR(50), -- synth, effect, utility, etc.
    tags TEXT[], -- wavetable, reverb, compressor, etc.
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_plugin_catalog_name ON plugin_catalog(name);

-- Analytics (for tracking feature usage)
CREATE TABLE analytics_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    event_type VARCHAR(50) NOT NULL, -- 'scan', 'backup', 'share', 'check_compatibility'
    event_data JSONB,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_analytics_user_id ON analytics_events(user_id);
CREATE INDEX idx_analytics_created_at ON analytics_events(created_at);
```

## Backend API Implementation (FastAPI)

### Project Structure

```
audioenv-backend/
├── app/
│   ├── __init__.py
│   ├── main.py                    # FastAPI app entry point
│   ├── config.py                  # Environment variables, S3 config
│   ├── database.py                # SQLAlchemy setup
│   ├── dependencies.py            # Auth dependency injection
│   │
│   ├── routers/
│   │   ├── __init__.py
│   │   ├── auth.py                # /api/auth/* endpoints
│   │   ├── plugins.py             # /api/plugins/* endpoints
│   │   ├── projects.py            # /api/projects/* endpoints
│   │   └── stats.py               # /api/stats endpoint
│   │
│   ├── models/
│   │   ├── __init__.py
│   │   ├── user.py                # SQLAlchemy User model
│   │   ├── plugin.py              # UserPlugin model
│   │   ├── project.py             # Project model
│   │   └── backup.py              # BackupJob model
│   │
│   ├── schemas/
│   │   ├── __init__.py
│   │   ├── user.py                # Pydantic User schemas
│   │   ├── plugin.py              # Plugin request/response schemas
│   │   ├── project.py             # Project schemas
│   │   └── backup.py              # Backup schemas
│   │
│   ├── services/
│   │   ├── __init__.py
│   │   ├── s3_service.py          # S3 upload/download logic
│   │   ├── deduplication.py       # Plugin deduplication
│   │   └── compatibility.py       # Project compatibility checking
│   │
│   └── websockets/
│       ├── __init__.py
│       └── backup_progress.py     # WebSocket for backup progress
│
├── tests/
│   ├── test_plugins.py
│   ├── test_projects.py
│   └── test_s3_service.py
│
├── alembic/                       # Database migrations
│   ├── versions/
│   └── env.py
│
├── requirements.txt
├── Dockerfile
└── docker-compose.yml
```

### Key Backend Code Snippets

#### `app/main.py`
```python
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.routers import auth, plugins, projects, stats
from app.websockets import backup_progress

app = FastAPI(title="AudioEnv API", version="1.0.0")

# CORS for macOS app
app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://audioenv.app", "http://localhost:*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(auth.router, prefix="/api/auth", tags=["auth"])
app.include_router(plugins.router, prefix="/api/plugins", tags=["plugins"])
app.include_router(projects.router, prefix="/api/projects", tags=["projects"])
app.include_router(stats.router, prefix="/api/stats", tags=["stats"])

# WebSocket endpoint
app.include_router(backup_progress.router)

@app.get("/")
def read_root():
    return {"message": "AudioEnv API", "version": "1.0.0"}
```

#### `app/routers/plugins.py`
```python
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from app import schemas, models
from app.dependencies import get_current_user, get_db
from app.services.s3_service import generate_presigned_urls

router = APIRouter()

@router.post("/backup/initiate")
async def initiate_backup(
    request: schemas.BackupInitiateRequest,
    current_user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Creates a backup job and generates presigned S3 URLs for uploading plugins.
    """
    # Create backup job
    job = models.BackupJob(
        user_id=current_user.id,
        job_type="plugins",
        status="pending",
        total_files=len(request.plugins),
        total_bytes=sum(p.size_bytes for p in request.plugins)
    )
    db.add(job)
    db.commit()

    # Generate presigned URLs for each plugin
    upload_urls = []
    for plugin in request.plugins:
        s3_key = f"users/{current_user.id}/plugins/{plugin.format}/{plugin.name}.zip"
        presigned_url = await generate_presigned_urls(
            bucket="audioenv-backups",
            key=s3_key,
            expiration=3600  # 1 hour
        )
        upload_urls.append({
            "plugin_id": plugin.id,
            "s3_key": s3_key,
            "presigned_url": presigned_url
        })

    return {
        "job_id": str(job.id),
        "upload_urls": upload_urls,
        "deduplicated_count": len(upload_urls)
    }

@router.post("/backup/complete")
async def complete_backup(
    request: schemas.BackupCompleteRequest,
    current_user: models.User = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    Marks a backup job as complete and saves plugin metadata.
    """
    job = db.query(models.BackupJob).filter(
        models.BackupJob.id == request.job_id,
        models.BackupJob.user_id == current_user.id
    ).first()

    if not job:
        raise HTTPException(status_code=404, detail="Backup job not found")

    job.status = "completed"
    job.completed_at = datetime.utcnow()
    job.uploaded_files = len(request.uploaded_plugins)

    # Save plugin metadata
    for plugin in request.uploaded_plugins:
        user_plugin = models.UserPlugin(
            user_id=current_user.id,
            plugin_name=plugin.name,
            plugin_format=plugin.format,
            bundle_id=plugin.bundle_id,
            s3_key=plugin.s3_key,
            file_size_bytes=plugin.size_bytes
        )
        db.add(user_plugin)

    db.commit()

    return {"status": "completed", "job_id": str(job.id)}
```

#### `app/services/s3_service.py`
```python
import boto3
from botocore.exceptions import ClientError

s3_client = boto3.client('s3')

async def generate_presigned_urls(bucket: str, key: str, expiration: int = 3600) -> str:
    """
    Generates a presigned URL for uploading to S3.
    """
    try:
        presigned_url = s3_client.generate_presigned_url(
            'put_object',
            Params={'Bucket': bucket, 'Key': key},
            ExpiresIn=expiration
        )
        return presigned_url
    except ClientError as e:
        raise Exception(f"Failed to generate presigned URL: {e}")

async def upload_to_s3(file_path: str, bucket: str, key: str):
    """
    Uploads a file to S3 using multipart upload for large files.
    """
    try:
        s3_client.upload_file(file_path, bucket, key)
    except ClientError as e:
        raise Exception(f"Failed to upload to S3: {e}")
```

## Deployment Architecture

```
┌────────────────────────────────────────────────────────────┐
│                     Production Setup                        │
└────────────────────────────────────────────────────────────┘

┌─────────────┐      HTTPS       ┌──────────────────┐
│  CloudFlare │ ─────────────────▶│  Load Balancer   │
│  (CDN/DNS)  │                   │  (ALB or Nginx)  │
└─────────────┘                   └────────┬─────────┘
                                           │
                                           │ Forward to
                                           ▼
                         ┌──────────────────────────────┐
                         │  FastAPI App (Dockerized)    │
                         │  • Runs on DigitalOcean      │
                         │  • 2 vCPU, 4GB RAM           │
                         │  • Auto-scaling (1-3 instances)
                         └────────┬──────────┬──────────┘
                                  │          │
                                  │          │
                ┌─────────────────┘          └─────────────────┐
                ▼                                              ▼
    ┌───────────────────────┐                    ┌────────────────────┐
    │  PostgreSQL (Supabase)│                    │   AWS S3 Bucket    │
    │  • Managed database   │                    │   audioenv-backups │
    │  • Daily backups      │                    │   • Versioned      │
    │  • Connection pooling │                    │   • Encrypted      │
    └───────────────────────┘                    └────────────────────┘
```

### Monitoring & Observability

- **Logging:** Structured logs via Python's `logging` module → CloudWatch or Datadog
- **Metrics:** Prometheus + Grafana for API response times, error rates
- **Alerts:** PagerDuty for critical failures (DB down, S3 errors)
- **Tracing:** OpenTelemetry for distributed tracing (future microservices)

---

## Security Checklist

- [ ] All passwords hashed with bcrypt (min 12 rounds)
- [ ] JWT tokens signed with RS256 (not HS256)
- [ ] API rate limiting: 100 req/min per IP, 1000 req/hour per user
- [ ] S3 bucket has deny public access policy
- [ ] HTTPS enforced (redirect HTTP → HTTPS)
- [ ] CORS restricted to audioenv.app domain
- [ ] SQL injection prevention (SQLAlchemy parameterized queries)
- [ ] Input validation with Pydantic on all endpoints
- [ ] Sensitive data (AWS keys) stored in environment variables, not code
- [ ] Regular dependency updates (Dependabot for Python + Swift)

---

## Performance Optimization

### Backend
- **Caching:** Redis for frequently accessed data (plugin catalog, user sessions)
- **Database Indexing:** See CREATE INDEX statements in schema
- **Connection Pooling:** SQLAlchemy pool size = 20, max overflow = 10
- **Async I/O:** Use `asyncio` for S3 operations, DB queries

### macOS App
- **Image Caching:** NSCache with size limits (see recommendations)
- **Lazy Loading:** LazyVStack for plugin/session lists
- **Background Scanning:** Use `.background` QoS for non-critical scans
- **Debounced Search:** 300ms delay on search input

### S3
- **Transfer Acceleration:** Enable for faster uploads from distant regions
- **Multipart Upload:** 50MB parts for large plugins
- **CloudFront CDN:** Cache plugin icons, reduce S3 GET costs

---

This architecture is designed to scale from 10 users to 10,000+ users without major rewrites. Start with the MVP (FastAPI + Supabase + S3), then optimize based on real usage patterns.
