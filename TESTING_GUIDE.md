# Backup Testing Guide - Free Tier Self-Managed S3

## How the Backup System Works

### Upload Process
When you click "Start Backup", here's what happens:

1. **Generate Backup ID**: Creates unique timestamp-based ID (e.g., `2026-02-06T16-45-12-ABC123`)

2. **For Each Plugin**:
   - Zip the plugin bundle → `plugin.zip` (in temp directory)
   - Upload to S3 at: `users/{your-uuid}/backups/{backup-id}/plugins/{plugin-checksum}.zip`
   - Clean up temp file
   - Log success/failure

3. **Upload Metadata**:
   - Create `metadata.json` with:
     - Backup info (name, date, scope)
     - List of all plugins with their **original paths**
     - S3 keys for each plugin
     - Plugin details (name, format, version, manufacturer)
   - Upload to: `users/{your-uuid}/backups/{backup-id}/metadata.json`

### What You'll See in S3
```
your-test-bucket/
  users/
    a1b2c3d4-e5f6-7890-abcd-ef1234567890/     # Your user UUID
      backups/
        2026-02-06T16-45-12-XYZ789/           # Backup session
          metadata.json                        # 📋 Manifest
          plugins/
            serum-vst3.zip                    # Individual plugin archives
            fabfilter-proq3-au.zip
            waves-ssl-vst.zip
```

### Restore Process (Future)
1. List backups from S3 (sorted by date)
2. User selects backup to restore
3. Download `metadata.json` → parse to see what's in the backup
4. Show user list of plugins with original paths
5. User selects plugins to restore + destination folder
6. Download selected `.zip` files from S3
7. Extract to chosen location (or original path)

## Testing as Free User with Own S3 Bucket

### Prerequisites

1. **AWS Account** with S3 access
2. **Create Test Bucket**:
   ```
   Name: audioenv-test-{yourname}
   Region: us-west-2 (or your preferred region)
   Settings:
     - Block all public access: ✅ ON
     - Bucket Versioning: Optional
     - Server-side encryption: ✅ Recommended
     - Object Lock: ❌ OFF
   ```

3. **Create IAM User** (or use existing):
   ```
   User name: audioenv-test-user
   Permissions: AmazonS3FullAccess (for testing - restrict in production)
   Access type: Programmatic access

   Save the credentials:
   - Access Key ID: AKIA...
   - Secret Access Key: wJalr...
   ```

### Step-by-Step Testing

#### 1. Configure S3 in App

```
1. Launch AudioEnv app
2. Login with your account
3. Navigate to "Backup" tab
4. Click "Configure S3 Backup"
5. Enter:
   - Bucket Name: audioenv-test-{yourname}
   - Access Key ID: AKIA...
   - Secret Access Key: wJalr...
   - Region: us-west-2
6. Click "Save & Connect"
```

**Expected Result**: ✅ "Connected to: S3 - audioenv-test-{yourname}"

#### 2. Select Backup Scope

```
1. Click "Select What to Backup"
2. Choose "Single Plugin" (for small test)
3. Pick a small plugin from dropdown (< 500MB recommended)
4. Click "Calculate Size"
```

**Expected Result**:
- Shows accurate plugin size (e.g., "456 MB")
- NOT "36 KB" (that bug is fixed!)

#### 3. Review Backup Preview

```
Check the Backup Scope section shows:
- Backup name: "Serum Plugin" (or similar)
- Description: "Only the 'Serum' plugin (VST3)"
- Stats:
  - Plugins: 1 (456 MB)
  - Total Size: 456 MB
```

#### 4. Perform Backup

```
1. Click "Start Backup"
2. Watch progress bar fill
3. Monitor upload log entries
```

**Expected Behavior**:
- Progress: 0% → 100%
- Status messages for each file
- Upload log shows:
  - Plugin zip upload: ✅ Success
  - metadata.json upload: ✅ Success
- No errors

**Estimated Time**:
- 100 MB: ~30 seconds
- 500 MB: ~2 minutes
- 1 GB: ~4 minutes
(Varies by internet speed)

#### 5. Verify in S3 Console

```
1. Open AWS S3 Console
2. Navigate to your bucket: audioenv-test-{yourname}
3. Browse: users/ → {your-uuid}/ → backups/ → {backup-id}/
```

**Expected Files**:
```
✅ metadata.json (few KB)
✅ plugins/
   └── serum-vst3.zip (matches size)
```

#### 6. Inspect metadata.json

```
1. Download metadata.json from S3
2. Open in text editor
```

**Expected Content**:
```json
{
  "appVersion": "1.0.0",
  "backupId": "2026-02-06T16-45-12-ABC123",
  "backupName": "Serum Plugin",
  "createdAt": "2026-02-06T16:45:12Z",
  "pluginCount": 1,
  "plugins": [
    {
      "bundleId": "com.xferrecords.Serum",
      "format": "VST3",
      "manufacturer": "Xfer Records",
      "name": "Serum",
      "originalPath": "/Library/Audio/Plug-Ins/VST3/Serum.vst3",
      "s3Key": "users/abc-123/backups/2026-02-06.../plugins/serum-vst3.zip",
      "version": "1.36"
    }
  ],
  "projectCount": 0,
  "projects": [],
  "scopeDescription": "Only the 'Serum' plugin (VST3)",
  "sessionCount": 0,
  "totalSizeBytes": 478150656,
  "userId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
}
```

**Key Fields to Verify**:
- ✅ `originalPath`: Exact path where plugin lives on your Mac
- ✅ `s3Key`: Where it is in S3 (for restore)
- ✅ `totalSizeBytes`: Matches actual plugin size

#### 7. Test Multi-Plugin Backup

```
1. Click "Change Scope"
2. Select "Custom Selection"
3. Toggle 3-5 small plugins
4. Click "Calculate Size"
5. Verify total is sum of individual sizes
6. Click "Continue" → "Start Backup"
```

**Expected Result**:
- Multiple plugin zips uploaded
- metadata.json lists all plugins
- Each with correct originalPath and s3Key

#### 8. Test Project Backup (Future)

```
Currently only plugins are backed up.
Projects will be added in next phase.
```

## Troubleshooting

### "No backup destination configured"
- Solution: Configure S3 credentials in Backup tab

### "User not authenticated"
- Solution: Login to your account first

### "Upload failed: 403 Forbidden"
- Check: IAM user has S3 write permissions
- Check: Bucket name is correct
- Check: Access keys are valid

### "Upload failed: 404 Not Found"
- Bucket doesn't exist
- Bucket is in different region than configured

### "Invalid credentials"
- Access Key ID or Secret Key is wrong
- Generate new credentials in IAM console

### Size still shows as KB
- Rebuild app: `swift build`
- Restart app
- If persists, check BackupScope.swift has recursive size calculation

### Upload very slow
- Normal for large plugins
- Check internet upload speed
- Consider starting with smaller plugins

## S3 Costs (Estimate)

**Storage** (us-west-2 rates):
- $0.023 per GB/month
- 10 GB of plugins = $0.23/month
- 100 GB = $2.30/month

**Transfer**:
- Upload (PUT): $0.005 per 1,000 requests
- 50 plugins = $0.00025
- Download (GET): $0.09 per GB

**Example Test Cost**:
- Upload 5 GB of plugins: ~$0.12
- Store for 1 month: ~$0.12
- Download once: ~$0.45
- **Total**: < $1.00

## Production Differences

For production paid tier users:

### What's Different:
1. **Auto-bucket creation**: Server creates bucket automatically
2. **Presigned URLs**: Server generates time-limited upload URLs
3. **No credentials in app**: User never sees AWS keys
4. **Quota enforcement**: Free (5GB), Pro (100GB), Unlimited
5. **Database tracking**: Each upload tracked in `user_plugins` table
6. **Storage billing**: Tracked in `users.storage_used_bytes`

### What's the Same:
- File structure identical
- metadata.json format identical
- Restore workflow identical
- Deduplication strategy identical

## Next Steps

After successful test:

1. **Verify size calculation**: Should show GB, not KB
2. **Check S3 structure**: Matches expected layout
3. **Inspect metadata.json**: Has original paths
4. **Test with multiple plugins**: Verify all upload correctly
5. **Plan restore workflow**: Design UI for downloading/extracting

## Questions to Consider

1. **Restore UX**: Where should restored plugins go?
   - Original path (requires sudo)?
   - User-selected folder?
   - Show both options?

2. **Deduplication**: Should we calculate SHA-256?
   - Pro: Better deduplication
   - Con: Slower backup start
   - Hybrid: Calculate on upload, cache in DB?

3. **Incremental backups**: Only upload changed plugins?
   - Track checksums in DB
   - Compare before upload
   - Skip if unchanged

4. **Project files**: Include project samples folder?
   - Can be huge (10+ GB)
   - Should be opt-in?
   - Separate storage quota?

5. **Compression**: Zip level 6 vs 9?
   - Faster vs smaller
   - Current: Default (6)
   - Could offer user preference
