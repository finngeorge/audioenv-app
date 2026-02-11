# S3 Backup Structure & Strategy

## Issues Fixed

### 1. Size Calculation Bug ✅
**Problem**: Backup preview showed 36KB instead of 20GB+ for plugins
**Root Cause**: `FileManager.attributesOfItem()` only returns directory metadata size, not bundle contents
**Solution**: Implemented recursive size calculation that traverses the entire plugin bundle

```swift
// Now correctly calculates total size of all files in bundle
private func getPluginSize(_ plugin: AudioPlugin) -> UInt64 {
    // Recursively sum all files in the bundle directory
    let enumerator = fileManager.enumerator(atPath: plugin.path)
    for each file in enumerator {
        totalSize += fileSize
    }
    return totalSize
}
```

### 2. S3 Bucket Organization ✅
**Implemented**: Structured, scalable bucket architecture with proper path generation

## S3 Bucket Structure

### Directory Layout
```
audioenv-backups/                           # Single shared bucket (RECOMMENDED)
  users/
    {user-uuid}/                            # Stable user identifier
      backups/
        2026-02-06T15-30-45-ABC123/         # Sortable backup ID
          metadata.json                     # Backup info, scope, stats
          plugins/
            serum-vst3.zip                  # Deduplicated by checksum
            fabfilter-proq3-au.zip
            waves-ssl-vst.zip
          projects/
            MyTrack-2024/
              MyTrack.als
              MyTrack-backup1.als
```

### Path Components

1. **User ID (UUID)**: Stable identifier that doesn't change if username changes
2. **Backup ID**: Timestamp + short UUID for sorting and uniqueness
3. **Plugin Checksum**: Enables deduplication (currently name+format, TODO: SHA-256)
4. **Project Hierarchy**: Maintains project folder structure

## Testing Strategy

### For Your Test
1. **Create Test Bucket**: `audioenv-test-finn` (or any name)
2. **Configure S3**: Use your AWS credentials in the app
3. **Start Small**:
   - Select "Single Plugin" scope
   - Choose a small plugin (~100MB)
   - Verify upload completes
   - Check S3 console for proper path structure

### Expected S3 Path
```
audioenv-test-finn/
  users/
    {your-user-uuid}/
      backups/
        2026-02-06T16-45-12-XYZ789/
          plugins/
            PluginName-VST3.zip
```

## Production Considerations

### Single Bucket Strategy (RECOMMENDED)
**Pros**:
- Simpler management (one bucket, one set of policies)
- Cost-effective (no per-bucket fees)
- Easier monitoring and logging
- Simpler IAM policies

**Cons**:
- All users in one namespace (mitigated by user-id folders)

### Access Control
- **IAM Policy**: Restrict users to `users/{their-uuid}/*`
- **Presigned URLs**: Server generates time-limited URLs for upload/download
- **Server-Side Auth**: Client never has direct bucket access

### Cost Optimization
1. **Deduplication**:
   - Current: By plugin name + format
   - Future: SHA-256 checksum (same plugin = same file)
   - Global dedup: Share plugins across users (optional, privacy considerations)

2. **Storage Classes**:
   - STANDARD: Recent backups (0-30 days)
   - STANDARD_IA: Older backups (30-90 days)
   - GLACIER: Archive (90+ days)
   - Configure lifecycle rules for auto-transition

3. **Compression**:
   - Plugins already zipped before upload
   - Projects compressed if beneficial

### User Tiers & Quotas
```swift
// Enforce before upload
switch user.subscriptionTier {
case "free":
    maxStorage = 5 * GB
case "pro":
    maxStorage = 100 * GB
case "unlimited":
    maxStorage = nil  // No limit
}

guard user.storageUsedBytes + uploadSize <= maxStorage else {
    throw "Storage quota exceeded"
}
```

### Database Tracking
Track uploads in `user_plugins` table:
- `s3_key`: Full S3 path
- `file_size_bytes`: For quota tracking
- `checksum`: SHA-256 for deduplication
- `uploaded_at`: Timestamp

Maintain `users.storage_used_bytes`:
- Increment on successful upload
- Decrement on deletion
- Periodic audit against S3 for accuracy

## Future Enhancements

### Bucket Auto-Creation (Paid Tier)
```python
# Backend creates bucket on first backup
def ensure_user_bucket(user_id: str) -> str:
    bucket_name = f"audioenv-backups"  # Shared bucket
    # Or per-user: f"audioenv-{user.username}-backups"

    if not s3.bucket_exists(bucket_name):
        s3.create_bucket(
            Bucket=bucket_name,
            ACL='private',
            CreateBucketConfiguration={'LocationConstraint': 'us-west-2'}
        )

        # Set lifecycle rules
        s3.put_bucket_lifecycle_configuration(
            Bucket=bucket_name,
            LifecycleConfiguration={
                'Rules': [
                    {
                        'Id': 'archive-old-backups',
                        'Status': 'Enabled',
                        'Transitions': [
                            {'Days': 30, 'StorageClass': 'STANDARD_IA'},
                            {'Days': 90, 'StorageClass': 'GLACIER'}
                        ]
                    }
                ]
            }
        )

    return bucket_name
```

### Restore Workflow
1. List user's backups: `s3.list(prefix=f"users/{user_id}/backups/")`
2. Show metadata.json for each backup
3. User selects backup to restore
4. Download plugins/projects to temp directory
5. Prompt user for install locations
6. Extract zips and copy to destination

### Incremental Backups
- Track checksums of previously uploaded files
- Only upload changed/new files
- Significant bandwidth savings for large environments

### Backup Scheduling
- Weekly auto-backup option
- Background uploads
- Notifications on completion

## Security Notes

### Username Uniqueness
- Already enforced at database level:
  ```python
  username = Column(String(50), unique=True, nullable=False, index=True)
  ```
- Backend validation on registration
- Prevents path collisions

### S3 Security Best Practices
1. **Never expose credentials**: Server-side only
2. **Use presigned URLs**: Time-limited, scoped access
3. **Encrypt at rest**: Enable S3 server-side encryption
4. **Encrypt in transit**: HTTPS only
5. **Audit logging**: Enable CloudTrail for compliance
6. **CORS policy**: Restrict to your domain

### Rate Limiting
Prevent abuse:
- Max 10 backups per day (free tier)
- Max 50 backups per day (pro tier)
- Cooldown between large uploads

## Monitoring & Alerts
- Track upload success/failure rates
- Alert on quota approaching limits
- Monitor S3 costs per user
- Detect unusual upload patterns

## Next Steps for Testing

1. **Create your test bucket** in AWS console:
   ```bash
   Bucket name: audioenv-test-finn
   Region: us-west-2
   Block all public access: ON
   Encryption: Enabled
   ```

2. **Configure credentials** in app:
   - Access Key ID
   - Secret Access Key
   - Region: us-west-2
   - Bucket: audioenv-test-finn

3. **Test backup workflow**:
   - Login to app
   - Select "Single Plugin" scope
   - Choose small plugin
   - Click "Start Backup"
   - Monitor upload progress
   - Verify in S3 console

4. **Verify structure**:
   - Check path matches expected structure
   - Verify file is zipped
   - Check size matches preview
   - Confirm metadata is accurate

5. **Test restore** (future):
   - List backups from S3
   - Download plugin zip
   - Extract and verify integrity
