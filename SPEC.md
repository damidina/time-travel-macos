# Time Travel macOS - Git Commit Backdating Script Specification

## Overview
This script enables backdating Git commits to fill in missing days in 2025 on GitHub's contribution graph. It uses macOS system date manipulation to create commits with historical dates.

## Requirements

### Functional Requirements
1. **Date Range**: Process all days in 2025 (January 1, 2025 - December 31, 2025)
2. **Commit Creation**: Create at least one commit per day that doesn't already have commits
3. **Date Accuracy**: Commits must be dated correctly to appear on the correct day in GitHub's contribution graph
4. **System Time Management**: Temporarily change system date/time, create commit, then restore original time
5. **Safety**: Restore system time even if script fails or is interrupted

### Technical Requirements
1. **macOS Compatibility**: Must work on macOS (uses `sntp` or `date` commands)
2. **Git Integration**: Uses Git to create commits with proper dates
3. **Error Handling**: Graceful error handling and time restoration
4. **Logging**: Provide feedback on progress and operations
5. **Dry Run Mode**: Optional mode to preview what would happen without making changes

## Implementation Details

### Date Setting Methods
1. **Primary Method**: Use `sudo sntp -sS time.apple.com` to sync time (modern macOS)
2. **Fallback Method**: Use `date` command with format `mmddHHMMyy` for manual date setting
3. **Git Date Override**: Use `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` environment variables as additional safety

### Commit Strategy
- Create a small file change (or modify existing file) for each day
- Use meaningful commit messages (e.g., "Update: 2025-01-15")
- Ensure commits are properly dated using both system time and Git environment variables

### Safety Features
1. **Time Backup**: Store current system time before making changes
2. **Time Restoration**: Always restore original time, even on error (use trap)
3. **Validation**: Verify date was set correctly before creating commit
4. **Skip Existing**: Check if commit already exists for a date before creating new one

## Script Behavior

### Input
- Optional: Start date (default: 2025-01-01)
- Optional: End date (default: 2025-12-31)
- Optional: Dry run flag

### Output
- Progress messages for each day processed
- Summary of commits created
- Error messages if any issues occur
- Final system time restoration confirmation

### Process Flow
1. Validate script is running on macOS
2. Check for sudo privileges (may be needed for date changes)
3. Backup current system time
4. For each day in range:
   - Check if commit already exists for that date
   - If not, set system date to that day
   - Create a commit with appropriate date
   - Verify commit was created successfully
5. Restore original system time
6. Display summary

## Edge Cases
- Handle leap year (2025 is not a leap year)
- Handle daylight saving time transitions
- Handle script interruption (Ctrl+C)
- Handle permission errors
- Handle network issues when syncing time
- Handle days that already have commits

## Security Considerations
- Script may require sudo for date changes
- User should review script before running
- Consider using Git date environment variables instead of system time changes (safer alternative)

## Alternative Approach (Safer)
Instead of changing system time, use Git's built-in date override:
- `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` environment variables
- `git commit --date` flag
- This avoids system time manipulation entirely

