#!/bin/bash

# Time Travel macOS - Git Commit Backdating Script
# Creates commits for missing days in 2025 to fill GitHub contribution graph

# Don't use set -e, we'll handle errors manually

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
START_DATE="2025-01-01"
END_DATE="2025-12-31"
DRY_RUN=false
USE_SYSTEM_TIME=true  # Default: Change system date (required for proper commits)
FORCE_RECREATE=false  # Delete existing commits and recreate
SUDO_TIMESTAMP=0  # Track when we last refreshed sudo

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --start-date)
            START_DATE="$2"
            shift 2
            ;;
        --end-date)
            END_DATE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --git-only)
            USE_SYSTEM_TIME=false
            shift
            ;;
        --system-time)
            USE_SYSTEM_TIME=true
            shift
            ;;
        --force-recreate)
            FORCE_RECREATE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --start-date DATE    Start date (YYYY-MM-DD, default: 2025-01-01)"
            echo "  --end-date DATE      End date (YYYY-MM-DD, default: 2025-12-31)"
            echo "  --dry-run            Preview what would happen without making changes"
            echo "  --git-only           Use Git date override only (default, safer, no sudo)"
            echo "  --system-time        Change system time (requires sudo, password cached)"
            echo "  --force-recreate     Delete existing commits and recreate (use if timezone is wrong)"
            echo "  --help               Show this help message"
            echo ""
            echo "Password file:"
            echo "  Create 'sudo_password.txt' in the repo directory with your sudo password"
            echo "  to avoid typing it. The script will use it automatically if it exists."
            echo "  (Make sure to add it to .gitignore for security!)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo -e "${RED}Error: This script is designed for macOS only${NC}"
    exit 1
fi

# Check if Git is available
if ! command -v git &> /dev/null; then
    echo -e "${RED}Error: Git is not installed${NC}"
    exit 1
fi

# Initialize Git repo if needed
if [ ! -d ".git" ]; then
    echo -e "${YELLOW}Initializing Git repository...${NC}"
    git init
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to initialize Git repository${NC}"
        exit 1
    fi
fi

# Force recreate: delete all commits and start fresh
if [ "$FORCE_RECREATE" = true ] && [ "$DRY_RUN" = false ]; then
    if git rev-parse --verify HEAD &>/dev/null; then
        echo -e "${YELLOW}Force recreate: Deleting all existing commits...${NC}"
        # Save remote configuration
        REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
        REMOTE_NAME="origin"
        
        # Delete all commits but keep files
        rm -rf .git
        git init
        
        # Restore remote if it existed
        if [ -n "$REMOTE_URL" ]; then
            git remote add "$REMOTE_NAME" "$REMOTE_URL"
            echo -e "${GREEN}Remote configuration preserved.${NC}"
        fi
        
        # Clean up commits directory (will be recreated)
        if [ -d "commits" ]; then
            rm -rf commits
        fi
        
        echo -e "${GREEN}Repository reset. Will recreate all commits with correct timezone.${NC}"
        echo ""
    fi
fi

# Backup current system time
ORIGINAL_DATE=$(date)
ORIGINAL_TIMESTAMP=$(date +%s)

# Password cache file (will be created with restricted permissions)
SUDO_PASSWORD_FILE=$(mktemp /tmp/sudo_pass_XXXXXX 2>/dev/null || echo "/tmp/sudo_pass_$$")
trap "rm -f '$SUDO_PASSWORD_FILE' 2>/dev/null" EXIT INT TERM
chmod 600 "$SUDO_PASSWORD_FILE" 2>/dev/null || true

# Function to run sudo with cached password
sudo_with_password() {
    if [ -f "$SUDO_PASSWORD_FILE" ] && [ -s "$SUDO_PASSWORD_FILE" ]; then
        # Use cached password via stdin
        # Pass all arguments to sudo
        cat "$SUDO_PASSWORD_FILE" | sudo -S "$@" 2>/dev/null
        return $?
    else
        # Fallback to regular sudo (will prompt)
        sudo "$@"
        return $?
    fi
}

# Function to restore system time
restore_time() {
    if [ "$USE_SYSTEM_TIME" = true ] && [ "$DRY_RUN" = false ]; then
        echo -e "${BLUE}Restoring system time...${NC}"
        # Try to sync with time server first
        if sudo_with_password sntp -sS time.apple.com 2>/dev/null; then
            echo -e "${GREEN}System time restored via time server${NC}"
        else
            # Fallback: restore from timestamp
            sudo_with_password date -r "$ORIGINAL_TIMESTAMP" 2>/dev/null || true
            echo -e "${GREEN}System time restored${NC}"
        fi
        # Clean up password file
        rm -f "$SUDO_PASSWORD_FILE" 2>/dev/null || true
    fi
}

# Set trap to restore time on exit
trap restore_time EXIT INT TERM

# Request sudo password once at the start if using system time
if [ "$USE_SYSTEM_TIME" = true ] && [ "$DRY_RUN" = false ]; then
    echo -e "${YELLOW}System time mode requires sudo privileges.${NC}"
    
    # Check if password file exists
    if [ -f "sudo_password.txt" ]; then
        echo -e "${GREEN}Found sudo_password.txt, using password from file...${NC}"
        cp "sudo_password.txt" "$SUDO_PASSWORD_FILE"
        chmod 600 "$SUDO_PASSWORD_FILE"
        echo -e "${GREEN}Password loaded from file.${NC}"
        echo ""
    else
        echo -e "${YELLOW}Please enter your password once (it will be cached securely for this session):${NC}"
        echo -e "${YELLOW}Tip: You can create 'sudo_password.txt' with your password to avoid typing it.${NC}"
        # Read password securely (hidden input)
        read -s SUDO_PASSWORD
        echo ""
        # Store password in temp file
        echo "$SUDO_PASSWORD" > "$SUDO_PASSWORD_FILE"
        SUDO_PASSWORD=""  # Clear from memory
        chmod 600 "$SUDO_PASSWORD_FILE"
        echo -e "${GREEN}Password cached. Will be used automatically for all sudo commands.${NC}"
        echo ""
    fi
fi

# Function to set system date
set_system_date() {
    local target_date=$1
    if [ "$USE_SYSTEM_TIME" = false ] || [ "$DRY_RUN" = true ]; then
        return 0
    fi
    
    # Format: date MMDDHHmmYY (e.g., 0101120025 for Jan 1, 2025 12:00)
    local date_str=$(date -j -f "%Y-%m-%d" "$target_date" "+%m%d%H%M%y")
    
    # Set date using cached password
    if sudo_with_password date "$date_str"; then
        # Verify the date was set correctly
        local current_date=$(date +%Y-%m-%d)
        if [ "$current_date" = "$target_date" ]; then
            return 0
        else
            echo -e "${YELLOW}Warning: Date may not have been set correctly (current: $current_date, target: $target_date)${NC}"
            return 1
        fi
    else
        echo -e "${RED}Failed to set system date${NC}"
        return 1
    fi
}

# Function to check if ANY commit exists for a date
commit_exists_for_date() {
    local target_date=$1
    local since=$(date -j -f "%Y-%m-%d" "$target_date" "+%Y-%m-%d 00:00:00" 2>/dev/null || echo "${target_date} 00:00:00")
    local until=$(date -j -f "%Y-%m-%d" "$target_date" "+%Y-%m-%d 23:59:59" 2>/dev/null || echo "${target_date} 23:59:59")
    
    # Check if there's ANY commit on this date (regardless of files)
    # Use --all to check all branches and commits
    if git log --all --since="$since" --until="$until" --format="%H" 2>/dev/null | grep -q .; then
        return 0  # Commit exists
    else
        return 1  # No commit exists
    fi
}

# Function to create commit for a date
create_commit_for_date() {
    local target_date=$1
    
    # Check if ANY commit already exists for this date
    if commit_exists_for_date "$target_date"; then
        # Return 2 to indicate skipped (commit already exists)
        # Only show skip message occasionally to reduce noise
        if [ $((RANDOM % 50)) -eq 0 ]; then
            echo -e "${YELLOW}Commit already exists for $target_date, skipping...${NC}"
        fi
        return 2
    fi
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY RUN] Would create commit for $target_date${NC}"
        return 0
    fi
    
    # Set system date and verify it
    if [ "$USE_SYSTEM_TIME" = true ]; then
        echo -e "${BLUE}Setting system date to $target_date...${NC}"
        if ! set_system_date "$target_date"; then
            echo -e "${RED}Failed to set system date for $target_date${NC}"
            return 1
        fi
        # Verify the date was set correctly
        local current_date=$(date +%Y-%m-%d)
        local current_time=$(date)
        echo -e "${GREEN}✓ System date verified: $current_time${NC}"
        if [ "$current_date" != "$target_date" ]; then
            echo -e "${RED}Error: Date mismatch! Expected $target_date but got $current_date${NC}"
            return 1
        fi
    fi
    
    # Create a random file for this commit
    local random_name=$(openssl rand -hex 8)
    local commit_file="commits/${target_date}-${random_name}.txt"
    
    # Create commits directory if it doesn't exist
    if ! mkdir -p commits; then
        echo -e "${RED}Failed to create commits directory${NC}"
        return 1
    fi
    
    # Create file with date and random content
    if ! cat > "$commit_file" <<EOF
Date: $target_date
Commit: $random_name
Generated: $(date)
Random data: $(openssl rand -base64 32)
EOF
    then
        echo -e "${RED}Failed to create file $commit_file${NC}"
        return 1
    fi
    
    # Stage the file
    if ! git add "$commit_file"; then
        echo -e "${RED}Failed to stage file $commit_file${NC}"
        return 1
    fi
    
    # Get current time (system date should already be set)
    local current_timestamp=$(date)
    local tz_offset=$(date +%z)
    
    # Create timestamp with local timezone (use current time, or noon if system time not set)
    local timestamp
    if [ "$USE_SYSTEM_TIME" = true ]; then
        # Use current system time (which we just set)
        timestamp=$(date "+%Y-%m-%d %H:%M:%S %z")
    else
        # Fallback: use noon with local timezone
        timestamp="${target_date} 12:00:00 ${tz_offset}"
    fi
    
    export GIT_AUTHOR_DATE="$timestamp"
    export GIT_COMMITTER_DATE="$timestamp"
    
    # Create commit with the current system date
    local commit_msg="Update: $target_date - $random_name"
    if git commit -m "$commit_msg" --date="$timestamp" 2>/dev/null; then
        return 0
    else
        echo -e "${RED}✗ Failed to create commit for $target_date${NC}"
        return 1
    fi
}

# Convert date to seconds for iteration
start_epoch=$(date -j -f "%Y-%m-%d" "$START_DATE" "+%s" 2>/dev/null)
if [ -z "$start_epoch" ]; then
    start_epoch=$(date -j -u -f "%Y-%m-%d %H:%M:%S" "$START_DATE 00:00:00" "+%s" 2>/dev/null)
fi

end_epoch=$(date -j -f "%Y-%m-%d" "$END_DATE" "+%s" 2>/dev/null)
if [ -z "$end_epoch" ]; then
    end_epoch=$(date -j -u -f "%Y-%m-%d %H:%M:%S" "$END_DATE 23:59:59" "+%s" 2>/dev/null)
fi

if [ -z "$start_epoch" ] || [ -z "$end_epoch" ]; then
    echo -e "${RED}Error: Invalid date format. Use YYYY-MM-DD${NC}"
    echo -e "${RED}Start: $START_DATE -> $start_epoch${NC}"
    echo -e "${RED}End: $END_DATE -> $end_epoch${NC}"
    exit 1
fi

echo -e "${BLUE}Date range: $START_DATE (epoch: $start_epoch) to $END_DATE (epoch: $end_epoch)${NC}"

# First pass: Identify which dates need commits
echo -e "${GREEN}Scanning dates from $START_DATE to $END_DATE...${NC}"
echo -e "${BLUE}Identifying dates that need commits...${NC}"

missing_dates=()
current_epoch=$start_epoch
total_days=0

while [ $current_epoch -le $end_epoch ]; do
    current_date=$(date -j -f "%s" "$current_epoch" "+%Y-%m-%d" 2>/dev/null || date -u -r "$current_epoch" "+%Y-%m-%d")
    
    if [ -z "$current_date" ]; then
        current_epoch=$((current_epoch + 86400))
        continue
    fi
    
    # Check if commit exists for this date
    if ! commit_exists_for_date "$current_date"; then
        missing_dates+=("$current_date")
    fi
    
    total_days=$((total_days + 1))
    current_epoch=$((current_epoch + 86400))
    
    # Progress indicator
    if [ $((total_days % 100)) -eq 0 ]; then
        echo -e "${BLUE}Scanned $total_days days, found ${#missing_dates[@]} missing commits...${NC}"
    fi
done

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Scan Complete:${NC}"
echo -e "  Total days in range: $total_days"
echo -e "  Dates with commits: $((total_days - ${#missing_dates[@]}))"
echo -e "  Dates needing commits: ${#missing_dates[@]}"
echo -e "${GREEN}========================================${NC}"
echo ""

if [ ${#missing_dates[@]} -eq 0 ]; then
    echo -e "${GREEN}All dates already have commits! Nothing to do.${NC}"
    exit 0
fi

# Show ALL dates that need commits
echo -e "${YELLOW}Complete list of dates that need commits (${#missing_dates[@]} total):${NC}"
for date in "${missing_dates[@]}"; do
    echo -e "  - $date"
done
echo ""

# Also save to a file for reference
echo "Dates needing commits:" > missing_dates.txt
for date in "${missing_dates[@]}"; do
    echo "$date" >> missing_dates.txt
done
echo -e "${GREEN}Full list saved to: missing_dates.txt${NC}"
echo ""

# Ask for confirmation if there are many dates
if [ ${#missing_dates[@]} -gt 50 ] && [ "$DRY_RUN" = false ]; then
    echo -e "${YELLOW}This will create ${#missing_dates[@]} commits. Continue? (y/n)${NC}"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        exit 0
    fi
    echo ""
fi

# Second pass: Process only the dates that need commits
echo -e "${GREEN}Starting commit backdating for ${#missing_dates[@]} dates${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN MODE: No changes will be made${NC}"
fi
if [ "$USE_SYSTEM_TIME" = true ]; then
    echo -e "${YELLOW}Using system time mode - will change macOS date for each commit${NC}"
    echo -e "${YELLOW}Requires sudo (password will be cached)${NC}"
else
    echo -e "${GREEN}Using Git date override only (no system time changes)${NC}"
fi
echo ""

commits_created=0
commits_skipped=0
processed=0

# Process only the missing dates
echo -e "${BLUE}Starting to process ${#missing_dates[@]} dates...${NC}"
if [ "$USE_SYSTEM_TIME" = true ]; then
    echo -e "${YELLOW}Password will be used automatically from cache for each date change.${NC}"
    echo -e "${YELLOW}Processing will start in 2 seconds...${NC}"
    sleep 2
    echo ""
fi

for current_date in "${missing_dates[@]}"; do
    processed=$((processed + 1))
    
    echo -e "${BLUE}[$processed/${#missing_dates[@]}] Processing $current_date...${NC}"
    create_commit_for_date "$current_date"
    result=$?
    
    if [ $result -eq 0 ]; then
        # Commit was created successfully
        commits_created=$((commits_created + 1))
        echo -e "${GREEN}✓ Created commit with file for $current_date ($commits_created/${#missing_dates[@]})${NC}"
    elif [ $result -eq 2 ]; then
        # Commit already existed (shouldn't happen, but handle it)
        commits_skipped=$((commits_skipped + 1))
        echo -e "${YELLOW}⚠ Commit already exists for $current_date (skipped)${NC}"
    else
        # Error occurred
        echo -e "${RED}✗ Error creating commit for $current_date (exit code: $result)${NC}"
    fi
    
    echo ""  # Blank line between each date for readability
done

echo -e "${BLUE}Finished processing all dates.${NC}"

# Verification: Check a few commits to confirm dates are correct
echo ""
echo -e "${BLUE}Verifying commits...${NC}"
verification_count=0
verification_passed=0

# Check first 5 commits that were created
for i in {0..4}; do
    if [ $i -lt ${#missing_dates[@]} ]; then
        check_date="${missing_dates[$i]}"
        commit_date=$(git log --since="$check_date 00:00:00" --until="$check_date 23:59:59" --format="%ai" | head -1 | cut -d' ' -f1)
        if [ "$commit_date" = "$check_date" ]; then
            verification_passed=$((verification_passed + 1))
            echo -e "${GREEN}✓ Verified: $check_date has commit dated $commit_date${NC}"
        else
            echo -e "${YELLOW}⚠ Warning: $check_date commit shows date $commit_date${NC}"
        fi
        verification_count=$((verification_count + 1))
    fi
done

# Check last commit
if [ ${#missing_dates[@]} -gt 0 ]; then
    last_idx=$((${#missing_dates[@]} - 1))
    check_date="${missing_dates[$last_idx]}"
    commit_date=$(git log --since="$check_date 00:00:00" --until="$check_date 23:59:59" --format="%ai" | head -1 | cut -d' ' -f1)
    if [ "$commit_date" = "$check_date" ]; then
        verification_passed=$((verification_passed + 1))
        echo -e "${GREEN}✓ Verified: $check_date has commit dated $commit_date${NC}"
    else
        echo -e "${YELLOW}⚠ Warning: $check_date commit shows date $commit_date${NC}"
    fi
    verification_count=$((verification_count + 1))
fi

echo ""
if [ $verification_passed -eq $verification_count ]; then
    echo -e "${GREEN}✓ All verified commits have correct dates!${NC}"
else
    echo -e "${YELLOW}⚠ Some commits may have incorrect dates.${NC}"
fi

# Summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Summary:${NC}"
echo -e "  Total days in range: $total_days"
echo -e "  Dates needing commits: ${#missing_dates[@]}"
echo -e "  Commits created: $commits_created"
echo -e "  Commits skipped: $commits_skipped"
echo -e "  Verification: $verification_passed/$verification_count passed"
echo -e "${GREEN}========================================${NC}"

# Check if remote is configured
if git remote | grep -q .; then
    echo ""
    echo -e "${YELLOW}Note: To see commits on GitHub's contribution graph:${NC}"
    echo -e "  1. Push commits to GitHub: ${BLUE}git push origin main${NC}"
    echo -e "  2. GitHub uses your local timezone for contribution dates"
    echo -e "  3. Future dates (2025) may not appear until we're in 2025"
fi

# Restore time (trap will also handle this, but explicit is good)
restore_time

echo ""
echo -e "${GREEN}Done!${NC}"

