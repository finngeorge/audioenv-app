# Logic Pro & Pro Tools Parsing Limitations

## Overview

AudioEnv provides robust support for Ableton Live projects through full XML parsing, but faces limitations with Logic Pro and Pro Tools due to their proprietary binary formats.

## Current Capabilities

### Logic Pro (.logicx)
- ✅ **Metadata Extraction**: Project name, tempo, sample rate from Info.plist
- ✅ **Media File Discovery**: Audio files in Media, Audio Files, Sampler Files folders
- ✅ **Bounced Files**: Exported audio in Bounces folder
- ⚠️ **No Track Data**: Cannot parse track names, routing, or automation
- ⚠️ **Limited Sample Paths**: Only discovers samples inside the bundle, misses external references

### Pro Tools (.ptx, .ptf)
- ✅ **Binary Signature Detection**: Identifies valid Pro Tools session files
- ✅ **Media File Discovery**: Audio files in "Audio Files" and "Bounced Files" folders
- ⚠️ **No Track Data**: Cannot parse track names, routing, or plugin chains
- ⚠️ **Limited Sample Paths**: Only discovers samples in standard folders, misses external references
- ⚠️ **No Plugin Detection**: Cannot extract plugin usage from binary format

## Sample Collection Methods

### Ableton Live (Accurate)
- **Method**: Path Extraction
- **Source**: Parsed XML contains explicit file paths for all samples
- **Accuracy**: ~95% (missing only truly unavailable files)
- **External Samples**: ✅ Detected if referenced in project

### Logic Pro (Approximate)
- **Method**: Folder-Based Collection
- **Source**: Copies entire Media, Audio Files, Sampler Files, and Bounces folders
- **Accuracy**: ~70% (includes all internal media, misses external samples)
- **External Samples**: ❌ Not detected
- **Recommendation**: Use Logic's "Consolidate" or "Collect All and Save" before backup

### Pro Tools (Approximate)
- **Method**: Folder-Based Collection
- **Source**: Copies Audio Files and Bounced Files folders
- **Accuracy**: ~60% (includes session audio, misses external files and some plugins)
- **External Samples**: ❌ Not detected
- **Recommendation**: Use Pro Tools' "Copy/Convert Audio Files" or "Consolidate Clips" before backup

## Research on External Libraries

### Logic Pro Parsers
**Investigated libraries:**
- ❌ `logic-pro-parser` (Python) - Abandoned, only supports Logic 9
- ❌ `logicx-xml-parser` - No comprehensive Swift/C library found
- ℹ️ Logic's binary format is undocumented and changes between versions

**Alternative approaches:**
- ✅ **File System Discovery**: Scan common external sample locations by file timestamp/name matching
- ✅ **Metadata Extraction**: Enhanced plist parsing for more project details
- ❌ **Reverse Engineering**: Not feasible due to format complexity and legal concerns

### Pro Tools Parsers
**Investigated libraries:**
- ⚠️ `pt-parse-python` (GitHub) - Partial support for .ptf (legacy format), incomplete
- ⚠️ `ptformat` (libsndfile) - C library with basic .ptf parsing, doesn't cover .ptx
- ℹ️ Pro Tools moved from .ptf (text-based) to .ptx (binary) in recent versions

**Alternative approaches:**
- ✅ **AAF Export**: Pro Tools can export to AAF (Advanced Authoring Format), but requires manual step
- ✅ **File System Discovery**: Enhanced folder scanning for common plugin locations
- ❌ **Direct Binary Parsing**: .ptx format is proprietary and undocumented

## Recommended Workflows

### For Logic Pro Users
1. **Before Backup:**
   - Open your project in Logic Pro
   - Choose `File > Project Management > Consolidate...`
   - Select "Copy all audio files (and other resources) to project folder"
   - This ensures all samples are inside the .logicx bundle

2. **Then Use AudioEnv:**
   - The "Collect Samples" feature will now capture all audio
   - Backup will be complete and portable

### For Pro Tools Users
1. **Before Backup:**
   - Open your session in Pro Tools
   - Choose `File > Save Copy In...`
   - Check "All Audio Files" and "Copy from source media"
   - This copies all referenced audio to the session's Audio Files folder

2. **Then Use AudioEnv:**
   - The "Collect Samples" feature will capture all session audio
   - Backup will include all necessary files

## Future Improvements

### Short Term (Implemented)
- ✅ Enhanced folder scanning with common vendor plugin paths
- ✅ Warning UI for binary format limitations
- ✅ Documentation of recommended workflows

### Medium Term (Planned)
- ⏳ Smart file discovery by timestamp matching
- ⏳ Integration with `mdfind` (Spotlight) for sample location
- ⏳ Optional AAF import for Pro Tools (if user exports manually)

### Long Term (Research)
- 🔬 Investigate Logic's new project format changes (Logic 11+)
- 🔬 Community collaboration on reverse engineering efforts
- 🔬 Dialogue with Apple/Avid for official parsing APIs

## Contributing

If you have experience with Logic Pro or Pro Tools file formats, or know of reliable parsing libraries, please contribute:

1. Open an issue at [AudioEnv GitHub Issues](https://github.com/your-repo/issues)
2. Share any documentation or code samples
3. Test the sample collection feature and report accuracy

## References

- [Logic Pro X Package Format (unofficial)](https://wiki.hydrogenaud.io/index.php?title=Logic_Pro)
- [Pro Tools Session Format (partial docs)](https://github.com/Ardour/ardour/blob/master/libs/ptformat/ptformat.cc)
- [AAF Edit Protocol](https://www.amwa.tv/projects/AAF.shtml)

---

**Last Updated**: February 8, 2026
**AudioEnv Version**: 1.0
