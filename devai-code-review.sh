#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

echo "Starting automated code review process (Docker Optimized - Corrected Parsing Patterns)..."

# Ensure the temporary file is removed even if the script exits unexpectedly
# Define the temporary file path early so the trap can reference it
COMMENT_FILE=$(mktemp /tmp/comment_body.XXXXXX)
trap 'rm -f "$COMMENT_FILE"' EXIT

# --- Log relevant CI variables for debugging ---
echo "--- CI Variable Debugging ---"
echo "CI_PIPELINE_SOURCE: ${CI_PIPELINE_SOURCE:-<not set>}"
echo "CI_MERGE_REQUEST_IID: ${CI_MERGE_REQUEST_IID:-<not set>}"
echo "CI_PROJECT_ID: ${CI_PROJECT_ID:-<not set>}"
echo "CI_API_V4_URL: ${CI_API_V4_URL:-<not set>}"
echo "CI_MERGE_REQUEST_DIFF_BASE_SHA: ${CI_MERGE_REQUEST_DIFF_BASE_SHA:-<not set>}"
echo "CI_MERGE_REQUEST_SHA: ${CI_MERGE_REQUEST_SHA:-<not set>}"
echo "CI_MERGE_REQUEST_SOURCE_BRANCH_SHA: ${CI_MERGE_REQUEST_SOURCE_BRANCH_SHA:-<not set>}"
echo "CI_MERGE_REQUEST_SOURCE_BRANCH_NAME: ${CI_MERGE_REQUEST_SOURCE_BRANCH_NAME:-<not set>}" # Added logging for branch name
echo "--- End CI Variable Debugging ---"


# --- Check for required environment variables ---
# The script now relies on GITLAB_API_TOKEN being set as a CI/CD variable
if [ -z "$GITLAB_API_TOKEN" ]; then
  echo "Error: GITLAB_API_TOKEN is not set. Cannot perform GitLab API actions. Ensure this variable is configured in your CI/CD settings with sufficient permissions."
  exit 1
fi

if [ -z "$CI_MERGE_REQUEST_IID" ]; then
  echo "Error: CI_MERGE_REQUEST_IID is not set. This script should only run on Merge Request pipelines."
  exit 1
fi

# Check if CI_MERGE_REQUEST_DIFF_BASE_SHA is set
if [ -z "$CI_MERGE_REQUEST_DIFF_BASE_SHA" ]; then
    echo "Error: GitLab MR variable CI_MERGE_REQUEST_DIFF_BASE_SHA is not set."
    exit 1
fi

# --- Determine the head SHA to use for git diff ---
MR_HEAD_SHA=""
if [ -n "$CI_MERGE_REQUEST_SHA" ]; then
    MR_HEAD_SHA="$CI_MERGE_REQUEST_SHA"
    echo "Using CI_MERGE_REQUEST_SHA for diff: $MR_HEAD_SHA"
elif [ -n "$CI_MERGE_REQUEST_SOURCE_BRANCH_SHA" ]; then
    MR_HEAD_SHA="$CI_MERGE_REQUEST_SOURCE_BRANCH_SHA"
    echo "Using CI_MERGE_REQUEST_SOURCE_BRANCH_SHA for diff: $MR_HEAD_SHA"
elif [ -n "$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME" ]; then
    # Fallback: Use the source branch name to get the latest SHA
    echo "CI_MERGE_REQUEST_SHA and CI_MERGE_REQUEST_SOURCE_BRANCH_SHA not set. Attempting to get SHA from CI_MERGE_REQUEST_SOURCE_BRANCH_NAME..."
    # Ensure the source branch is fetched
    git fetch origin $CI_MERGE_REQUEST_SOURCE_BRANCH_NAME
    # Get the SHA of the head of the source branch
    MR_HEAD_SHA=$(git rev-parse origin/$CI_MERGE_REQUEST_SOURCE_BRANCH_NAME)
    if [ -n "$MR_HEAD_SHA" ]; then
        echo "Successfully determined MR_HEAD_SHA from branch name: $MR_HEAD_SHA"
    else
        echo "Error: Could not determine MR_HEAD_SHA from CI_MERGE_REQUEST_SOURCE_BRANCH_NAME."
        exit 1
    fi
else
    echo "Error: Neither CI_MERGE_REQUEST_SHA, CI_MERGE_REQUEST_SOURCE_BRANCH_SHA, nor CI_MERGE_REQUEST_SOURCE_BRANCH_NAME is set. Cannot perform git diff."
    exit 1
fi


if [ -z "$GOOGLE_APPLICATION_CREDENTIALS_JSON" ]; then
  echo "Error: GOOGLE_APPLICATION_CREDENTIALS_JSON is not set. Cannot run devai-cli."
  exit 1
fi
if [ -z "$CI_PROJECT_ID" ] || [ -z "$CI_API_V4_URL" ]; then
    echo "Error: GitLab project variables (CI_PROJECT_ID, CI_API_V4_URL) are not set."
    exit 1
fi


echo "Required environment variables are set."

# --- Verify devai command is in PATH ---
echo "Verifying 'devai' command is in PATH..."
if ! which devai; then
    echo "Error: 'devai' command not found in PATH. Ensure devai-cli is installed in the Docker image."
    # Exit with an error code if the executable is not found
    exit 1
fi
echo "'devai' command found at: $(which devai)"
echo "--- End Executable Verification ---"


# Setup Google Cloud Authentication
# Use the service account key stored in the CI/CD variable
echo "$GOOGLE_APPLICATION_CREDENTIALS_JSON" > /tmp/key.json
export GOOGLE_APPLICATION_CREDENTIALS="/tmp/key.json"
echo "Google Cloud authentication configured."

# --- Get changed files in the MR ---
echo "Getting changed files in MR !${CI_MERGE_REQUEST_IID}..."
# Fetch the base SHA to compare against
git fetch origin $CI_MERGE_REQUEST_DIFF_BASE_SHA
# Fetch the head SHA to ensure it's available, using the determined MR_HEAD_SHA
git fetch origin $MR_HEAD_SHA
# Get the list of changed files (Added, Copied, Deleted, Modified, Renamed)
# We are primarily interested in Added, Modified, Renamed files for code review
# Using --diff-filter=AMR to get only Added, Modified, Renamed files
# Using -z allows reading filenames with spaces/special characters correctly with 'xargs -0'
mapfile -d '' CHANGED_FILES_ARRAY < <(git diff --name-only --diff-filter=AMR -z $CI_MERGE_REQUEST_DIFF_BASE_SHA $MR_HEAD_SHA)
echo "Changed files (read into array):"
# Add debugging to print the contents of the array
for i in "${!CHANGED_FILES_ARRAY[@]}"; do
  echo "  File $i: ${CHANGED_FILES_ARRAY[$i]}"
done
echo ""

# --- Get the current working directory (repository root) ---
REPO_ROOT=$(pwd)
echo "Repository root (current working directory): $REPO_ROOT"
echo ""

# --- Run devai code-review with absolute paths formatted as a Python list string ---
echo "Running automated code review using 'devai review code --context' with absolute paths formatted as a Python list string..."
DEVAICLI_OUTPUT=""
# Check if the array is not empty
if [ ${#CHANGED_FILES_ARRAY[@]} -gt 0 ]; then
  # Construct a string that looks like a Python list of absolute file paths
  PYTHON_LIST_STRING="["
  first_file=true
  for file in "${CHANGED_FILES_ARRAY[@]}"; do
    if [ "$first_file" = true ]; then
      PYTHON_LIST_STRING+="'${REPO_ROOT}/${file}'"
      first_file=false
    else
      PYTHON_LIST_STRING+=", '${REPO_ROOT}/${file}'"
    fi
  done
  PYTHON_LIST_STRING+="]"

  echo "Passing the following string to --context: $PYTHON_LIST_STRING"

  # Run code-review by passing the constructed Python list string to --context
  # Capture both standard output and standard error.
  # Using '|| true' so the script doesn't exit immediately if devai returns a non-zero exit code
  # due to findings. We handle failure logic later.
  DEVAICLI_REVIEW_RESULT=$(devai review code -o markdown --context "$PYTHON_LIST_STRING" 2>&1) || true
  DEVAICLI_OUTPUT="$DEVAICLI_REVIEW_RESULT"
  echo "'devai review code --context' command completed."
  echo "Combined devai-cli output:"
  echo "$DEVAICLI_OUTPUT"
else
  echo "No relevant files changed to review. Skipping devai review."
  # Set output to a message indicating no review was performed
  DEVAICLI_OUTPUT="No relevant files changed to review. Automated review skipped."
fi

# --- Parse devai-cli output and determining score ---
echo "Parsing devai-cli output and determining score..."

# Add debugging: Print the output being parsed
echo "--- Output being parsed ---"
echo "$DEVAICLI_OUTPUT"
echo "--- End Output being parsed ---"

# Initialize score - lower is better
REVIEW_SCORE=0

# Initialize issue counts
CRITICAL_ISSUES=0
HIGH_ISSUES=0
MEDIUM_ISSUES=0
LOW_ISSUES=0

# --- Parsing logic based on severity in square brackets ---

echo "Counting Critical Issues (lines containing '[CRITICAL]')..."
# Add debugging: Print the exact grep command
echo "Executing: echo \"\$DEVAICLI_OUTPUT\" | grep \" *\[CRITICAL\]\" | wc -l"
# Use grep to filter lines and wc -l to count, capture output, and check for success
CRITICAL_ISSUES_RAW=$(echo "$DEVAICLI_OUTPUT" | grep " *\[CRITICAL\]" | wc -l 2>&1) # Capture stderr as well
WC_CRITICAL_EXIT_CODE=$?
if [ $WC_CRITICAL_EXIT_CODE -ne 0 ]; then
  echo "Warning: wc -l failed while counting Critical Issues. Exit code: $WC_CRITICAL_EXIT_CODE. Stderr: $CRITICAL_ISSUES_RAW. Assuming count is 0." >&2
  CRITICAL_ISSUES_RAW=0 # Set to 0 if wc -l fails
fi
CRITICAL_ISSUES=$((CRITICAL_ISSUES_RAW)) # Explicitly treat as integer
echo "Raw count output for Critical Issues: $CRITICAL_ISSUES_RAW"
echo "CRITICAL_ISSUES variable value: $CRITICAL_ISSUES"

echo "Counting High Issues (lines containing '[HIGH]')..."
# Use grep to filter lines and wc -l to count, capture output, and check for success
HIGH_ISSUES_RAW=$(echo "$DEVAICLI_OUTPUT" | grep " *\[HIGH\]" | wc -l 2>&1) # Capture stderr as well
WC_HIGH_EXIT_CODE=$?
if [ $WC_HIGH_EXIT_CODE -ne 0 ]; then
  echo "Warning: wc -l failed while counting High Issues. Exit code: $WC_HIGH_EXIT_CODE. Stderr: $HIGH_ISSUES_RAW. Assuming count is 0." >&2
  HIGH_ISSUES_RAW=0 # Set to 0 if wc -l fails
fi
HIGH_ISSUES=$((HIGH_ISSUES_RAW)) # Explicitly treat as integer
echo "Raw count output for High Issues: $HIGH_ISSUES_RAW"
echo "HIGH_ISSUES variable value: $HIGH_ISSUES"

echo "Counting Medium Issues (lines containing '[MEDIUM]')..."
# Use grep to filter lines and wc -l to count, capture output, and check for success
MEDIUM_ISSUES_RAW=$(echo "$DEVAICLI_OUTPUT" | grep " *\[MEDIUM\]" | wc -l 2>&1) # Capture stderr as well
WC_MEDIUM_EXIT_CODE=$?
if [ $WC_MEDIUM_EXIT_CODE -ne 0 ]; then
  echo "Warning: wc -l failed while counting Medium Issues. Exit code: $WC_MEDIUM_EXIT_CODE. Stderr: $MEDIUM_ISSUES_RAW. Assuming count is 0." >&2
  MEDIUM_ISSUES_RAW=0 # Set to 0 if wc -l fails
fi
MEDIUM_ISSUES=$((MEDIUM_ISSUES_RAW)) # Explicitly treat as integer
echo "Raw count output for Medium Issues: $MEDIUM_ISSUES_RAW"
echo "MEDIUM_ISSUES variable value: $MEDIUM_ISSUES"

echo "Counting Low Issues (lines containing '[LOW]')..."
# Use grep to filter lines and wc -l to count, capture output, and check for success
LOW_ISSUES_RAW=$(echo "$DEVAICLI_OUTPUT" | grep " *\[LOW\]" | wc -l 2>&1) # Capture stderr as well
WC_LOW_EXIT_CODE=$?
if [ $WC_LOW_EXIT_CODE -ne 0 ]; then
  echo "Warning: wc -l failed while counting Low Issues. Exit code: $WC_LOW_EXIT_CODE. Stderr: $LOW_ISSUES_RAW. Assuming count is 0." >&2
  LOW_ISSUES_RAW=0 # Set to 0 if wc -l fails
fi
LOW_ISSUES=$((LOW_ISSUES_RAW)) # Explicitly treat as integer
echo "Raw count output for Low Issues: $LOW_ISSUES_RAW"
echo "LOW_ISSUES variable value: $LOW_ISSUES"


echo "Calculating score based on severity..."
# Calculate score: Critical = 40, High = 30, Medium = 10, Low = 0
# Use shell arithmetic expansion
SCORE_CRITICAL=$((CRITICAL_ISSUES * 40))
SCORE_HIGH=$((HIGH_ISSUES * 30))
SCORE_MEDIUM=$((MEDIUM_ISSUES * 10))
SCORE_LOW=$((LOW_ISSUES * 0)) # Low issues don't add to the score

REVIEW_SCORE=$((SCORE_CRITICAL + SCORE_HIGH + SCORE_MEDIUM + SCORE_LOW))

echo "Score from Critical Issues: $SCORE_CRITICAL"
echo "Score from High Issues: $SCORE_HIGH"
echo "Score from Medium Issues: $SCORE_MEDIUM"
echo "Score from Low Issues: $SCORE_LOW"
echo "Calculated Final Review Score: $REVIEW_SCORE"

# --- End of parsing logic ---


# --- Determine overall review outcome and failure reason ---
echo "Determining overall review outcome..."
REVIEW_PASSED="true"
FAILURE_REASON=""

# Fail if score is 30 or higher
if [ "$REVIEW_SCORE" -ge 30 ]; then
  REVIEW_PASSED="false"
  FAILURE_REASON="Code review failed: Score ($REVIEW_SCORE) is 30 or higher."
fi

echo "Review Passed: $REVIEW_PASSED"
if [ "$REVIEW_PASSED" == "false" ]; then
    echo "Failure Reason: $FAILURE_REASON"
fi


# --- Add a comment to the Merge Request with the full devai-cli output ---
echo "Adding a comment to MR !${CI_MERGE_REQUEST_IID} with full devai-cli output..."

# --- Debugging: Print variables used in curl URL ---
echo "--- Curl URL Debugging ---"
echo "CI_API_V4_URL: ${CI_API_V4_URL}"
echo "CI_PROJECT_ID: ${CI_PROJECT_ID}"
echo "CI_MERGE_REQUEST_IID: ${CI_MERGE_REQUEST_IID}"
# Construct the full URL in a separate variable
GITLAB_MR_NOTES_URL="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CI_MERGE_REQUEST_IID}/notes"
echo "Constructed URL: ${GITLAB_MR_NOTES_URL}"
echo "--- End Curl URL Debugging ---"

# Add a check to ensure the URL variable is not empty
if [ -z "$GITLAB_MR_NOTES_URL" ]; then
  echo "Error: Constructed GitLab MR Notes URL is empty. Cannot post comment."
  exit 1
fi

# Filter out DEBUG lines from devai-cli output for the comment
FILTERED_DEVAICLI_OUTPUT=$(echo "$DEVAICLI_OUTPUT" | grep -v '^DEBUG:')

# Construct the Markdown scoring summary
SCORING_SUMMARY=$(cat <<EOF
## Code Review Scoring

**Score:** $REVIEW_SCORE (Lower is better)

**Issue Breakdown:**
- Critical: $CRITICAL_ISSUES
- High: $HIGH_ISSUES
- Medium: $MEDIUM_ISSUES
- Low: $LOW_ISSUES

---

EOF
)

# Combine the scoring summary and the filtered devai-cli output for the comment body
COMMENT_BODY="${SCORING_SUMMARY}\nAutomated code review results:\n\n"

if [ -n "$FILTERED_DEVAICLI_OUTPUT" ]; then
     COMMENT_BODY="${COMMENT_BODY}Detailed devai-cli output:\n\`\`\`\n${FILTERED_DEVAICLI_OUTPUT}\n\`\`\`"
else
     COMMENT_BODY="${COMMENT_BODY}No detailed devai-cli output available."
fi

# Escape special characters in COMMENT_BODY for JSON payload
# Use printf %s to handle newlines correctly with sed
ESCAPED_COMMENT_BODY=$(printf "%s" "$COMMENT_BODY" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g' | sed ':a;N;$!ba;s/\n/\\n/g')


# --- Use temporary file for curl data ---
# The temporary file is created and trapped at the beginning of the script.

# Write the JSON payload to the temporary file using jq for robustness
# This ensures the JSON is correctly formatted, especially with escaped characters.
jq --null-input \
   --arg body "$COMMENT_BODY" \
   '{body: $body}' > "$COMMENT_FILE"

# Construct the curl command using an array for clarity and robustness
CURL_COMMAND=(
  curl  # -i Include headers in the output for debugging
  --request POST
  --header "Private-Token: $GITLAB_API_TOKEN"
  --header "Content-Type: application/json"
  --data "@${COMMENT_FILE}" # Use the @ symbol to read the data from the file
  "${GITLAB_MR_NOTES_URL}" # Add the URL as the last argument
)

echo "Executing curl command:"
# Print the command elements for debugging (optional)
# printf "%q " "${CURL_COMMAND[@]}"; echo

# Execute the curl command using the array
# The "${CURL_COMMAND[@]}" expands the array into separate arguments
"${CURL_COMMAND[@]}"

# The trap command set earlier will handle the file cleanup upon script exit.
# No need for an explicit rm here if trap is used.

# --- End temporary file for curl data ---

echo "Comment added."


# --- Conditional Approval/Rejection and Pipeline Failure ---
echo "Performing conditional approval/rejection..."
if [ "$REVIEW_PASSED" == "true" ]; then
  echo "Code review passed. Approving Merge Request !${CI_MERGE_REQUEST_IID}..."
  # Construct the approval URL
  GITLAB_MR_APPROVE_URL="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CI_MERGE_REQUEST_IID}/approve"
  echo "Approval URL: ${GITLAB_MR_APPROVE_URL}"
  curl_approve_response=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Private-Token: $GITLAB_API_TOKEN" \
    "$(printf "%s" "$GITLAB_MR_APPROVE_URL")")

  if [ "$curl_approve_response" -eq 201 ]; then
    echo "Merge Request approved."
    exit 0
  else
    echo "Error: Failed to approve Merge Request. HTTP status code: $curl_approve_response"
    exit 1
  fi
else
  echo "Code review failed. Failing pipeline..."
  # Construct the unapprove URL
  GITLAB_MR_UNAPPROVE_URL="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/merge_requests/${CI_MERGE_REQUEST_IID}/unapprove"
  echo "Unapprove URL: ${GITLAB_MR_UNAPPROVE_URL}"

  # Gracefully attempt to unapprove the MR
  curl_unapprove_response=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Private-Token: $GITLAB_API_TOKEN" \
    "$(printf "%s" "$GITLAB_MR_UNAPPROVE_URL")")

  if [ "$curl_unapprove_response" -eq 404 ]; then
    echo "Merge Request was not approved; ignoring unapprove attempt."
  elif [ "$curl_unapprove_response" -eq 201 ]; then
     echo "Merge Request unapproved."
  else
    echo "Warning: Unexpected error while attempting to unapprove Merge Request. HTTP status code: $curl_unapprove_response" >&2
    # Continue with failing the job even if unapprove fails unexpectedly
  fi

  # Script exits with a non-zero status code (failure)
  exit 1
fi
