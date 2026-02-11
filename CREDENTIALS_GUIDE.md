# Credential Storage Guide

## What Gets Stored Where

### 1. Authentication Token (JWT)
**Stored in**: macOS Keychain
**Prompt**: "AudioEnv wants to access key 'authToken' in your keychain"
**Contains**: Your login session token
**Why Keychain**: Encrypted, secure, industry standard
**Action**: Click "Always Allow" for best experience

### 2. S3 Credentials
**Stored in**:
- Keychain (Access Key ID, Secret Access Key) - **SECURE**
- UserDefaults (Bucket Name, Region) - **NON-SENSITIVE**

**Why Split Storage**:
- Sensitive keys → Keychain (encrypted)
- Config values → UserDefaults (faster access)

**Persistence**: ✅ Saved between app launches

## First-Time Setup Flow

### Step 1: Login (One-Time Keychain Prompt)
```
1. Launch app
2. Go to Profile tab
3. Click "Login"
4. Enter email/password

Keychain Prompt:
  "AudioEnv wants to access key 'authToken' in your keychain"

  Options:
  → Always Allow (RECOMMENDED - never ask again)
  → Allow (ask each time - annoying)
  → Deny (won't stay logged in)

Choose: Always Allow
```

### Step 2: Configure S3 (Saved to Keychain)
```
1. Go to Backup tab
2. Click "Configure S3 Backup"
3. Enter:
   - Bucket Name: audioenv-test-finn
   - Access Key ID: AKIA...
   - Secret Access Key: wJalr...
   - Region: us-west-2
4. Click "Save & Connect"

Behind the scenes:
  ✅ Bucket name → UserDefaults
  ✅ Region → UserDefaults
  ✅ Access Key ID → Keychain (encrypted)
  ✅ Secret Key → Keychain (encrypted)
```

## On Subsequent App Launches

### What Happens Automatically
```
App Launch:
  ✅ Loads auth token from Keychain
  ✅ Checks if still valid
  ✅ Loads S3 config from Keychain
  ✅ Auto-reconnects to S3
  ✅ Shows green "Connected" status

You see:
  Profile tab: ✅ Already logged in
  Backup tab: ✅ Already connected to S3
```

### No Re-Prompting
Because you clicked "Always Allow", you won't see the Keychain prompt again unless:
- You reinstall the app
- You manually deny access in Keychain Access.app
- You clear Keychain items

## Managing Stored Credentials

### View/Edit in Keychain Access.app
```
1. Open: /Applications/Utilities/Keychain Access.app
2. Search: "audioenv" or "com.audioenv"
3. You'll see:
   - com.audioenv.s3.accessKeyId
   - com.audioenv.s3.secretKey
   - authToken (if using Keychain for auth)

Right-click → Get Info → Show password (requires Mac password)
```

### Disconnect S3
```
In app:
  Backup tab → Disconnect button

This will:
  ✅ Remove from Keychain
  ✅ Clear UserDefaults
  ✅ Disconnect S3 destination

Next time:
  Need to re-enter credentials
```

### Logout
```
In app:
  Profile tab → Logout button

This will:
  ✅ Clear auth token
  ✅ Return to login screen

S3 credentials remain saved (separate from auth)
```

### Full Reset
```
To clear everything:
  1. Backup tab → Disconnect
  2. Profile tab → Logout
  3. (Optional) Keychain Access → Delete audioenv items
```

## Security Best Practices

### ✅ What We Do Right
- **Keychain storage**: Industry standard, encrypted at rest
- **No plaintext files**: Credentials never in config files
- **Separate storage**: Auth vs S3 credentials isolated
- **Access control**: Requires Mac password to view
- **Automatic cleanup**: Disconnect removes from Keychain

### 🔒 Additional Security Tips
- Use IAM user (not root account) for S3
- Rotate S3 keys every 90 days
- Use restrictive IAM policy (limit to specific bucket)
- Enable MFA on AWS account
- Don't share Mac login password

## Troubleshooting

### "AudioEnv wants to access..." every time
**Cause**: Clicked "Allow" instead of "Always Allow"
**Fix**:
```
1. Keychain Access.app
2. Search: authToken
3. Right-click → Get Info
4. Access Control tab
5. Add AudioEnv to "Always allow access by these applications"
```

### S3 not auto-connecting on launch
**Cause**: Credentials not in Keychain
**Fix**: Re-enter in Backup tab, click "Save & Connect"

### "Access Denied" when uploading
**Cause**: IAM keys changed or expired
**Fix**:
```
1. Backup tab → Disconnect
2. Generate new keys in AWS IAM
3. Configure S3 Backup again
```

### Can't find credentials in Keychain
**Search for**:
- `com.audioenv.s3.accessKeyId`
- `com.audioenv.s3.secretKey`
- Account name matches exactly

### Want to move to different bucket
**Process**:
```
1. Backup tab → Disconnect (clears old bucket)
2. Configure S3 Backup (enter new bucket)
3. Old credentials removed, new ones saved
```

## What Happens on Uninstall

**App Uninstall**:
- App binary deleted
- ✅ Keychain items REMAIN (macOS behavior)
- UserDefaults REMAIN

**Complete Cleanup**:
```
1. Uninstall app
2. Open Keychain Access
3. Search: audioenv
4. Delete all items
5. Terminal:
   defaults delete com.audioenv.AudioEnv
```

## Production vs Testing

### Testing (Current)
- User provides own S3 bucket
- User manages own IAM keys
- Stored in user's Keychain
- User rotates keys manually

### Production (Future)
- Server manages buckets
- Server generates presigned URLs
- No AWS keys in client app
- Automatic expiration/rotation

Both secure, different trust models:
- Testing: You trust yourself with keys
- Production: You trust server to manage access
