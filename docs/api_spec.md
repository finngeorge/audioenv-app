# AudioEnv Backend API Specification

## Authentication
All authenticated endpoints require JWT bearer token:
```
Authorization: Bearer <token>
```

## Endpoints

### Authentication
```
POST /api/auth/register
Body: { email, username, password }
Response: { user_id, token }

POST /api/auth/login
Body: { email, password }
Response: { user_id, token, expires_at }

POST /api/auth/refresh
Header: Authorization: Bearer <refresh_token>
Response: { token, expires_at }
```

### Plugin Collection Management

```
POST /api/plugins/scan
Body: { plugins: [AudioPlugin] } // Upload current scan results
Response: { new_count, updated_count, duplicate_count }

GET /api/plugins
Response: { plugins: [UserPlugin], total_count, last_sync }

POST /api/plugins/backup/initiate
Body: {
  plugins: [{ name, format, bundleID, path, size_bytes }],
  prefer_format: "VST3" // For deduplication
}
Response: {
  job_id,
  upload_urls: [{ plugin_id, presigned_url, s3_key }],
  deduplicated_count
}

POST /api/plugins/backup/complete
Body: { job_id, uploaded_plugins: [{ plugin_id, s3_key, success }] }
Response: { status, failed_uploads: [] }

GET /api/plugins/backup/{job_id}
Response: {
  job_id,
  status,
  progress: { uploaded_files, total_files, uploaded_bytes, total_bytes },
  error_message
}
```

### Project Spec Sharing

```
POST /api/projects/share
Body: {
  name: "My Session",
  format: "Ableton",
  required_plugins: [
    { name: "Serum", formats: ["VST3"], bundleID: "com.xferrecords.serum" },
    { name: "FabFilter Pro-Q 3", formats: ["AU", "VST3"], bundleID: "com.fabfilter.proq3" }
  ]
}
Response: {
  share_token: "abc123xyz",
  share_url: "https://audioenv.app/check/abc123xyz",
  expires_at
}

GET /api/projects/check/{share_token}
Query: ?user_id=<optional> // If authenticated, check against their collection
Response: {
  project_name,
  format,
  required_plugins: [
    {
      name: "Serum",
      formats: ["VST3"],
      bundleID: "com.xferrecords.serum",
      user_has: true, // If user_id provided
      user_formats: ["VST3"] // Formats the user owns
    },
    {
      name: "FabFilter Pro-Q 3",
      formats: ["AU", "VST3"],
      user_has: false
    }
  ],
  compatibility_score: 0.5, // Percentage of plugins user has
  missing_plugins: [...]
}

GET /api/projects
Response: { projects: [Project], count }

DELETE /api/projects/{id}
Response: { success: true }
```

### Statistics & Analytics

```
GET /api/stats
Response: {
  total_plugins,
  plugins_by_format: { AU: 120, VST3: 340, ... },
  total_storage_bytes,
  most_common_plugins: [{ name, user_count }],
  backup_status: { last_backup, next_scheduled }
}
```

## WebSocket for Real-Time Progress

```
WS /api/ws/backup/{job_id}
Server messages:
{
  "type": "progress",
  "uploaded_files": 15,
  "total_files": 120,
  "uploaded_bytes": 2500000000,
  "total_bytes": 20000000000,
  "current_file": "Serum.vst3"
}
{
  "type": "completed",
  "success": true
}
```
