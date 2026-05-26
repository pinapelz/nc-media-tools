#!/usr/bin/env bash
set -eEuo pipefail

usage() {
  cat <<'EOF'
Usage:
  grab.sh -l <download_link> -r <rclone_remote> -u <upload_dir> -n <ntfy_topic> [options]

Required args:
  -l, --link           Direct download link for aria2c
  -r, --remote         Rclone remote name (example: gdrive)
  -u, --upload-dir     Destination directory on the remote (example: Movies/2026)
  -n, --ntfy-topic     ntfy topic to publish notifications to

Optional args:
  -s, --ntfy-server    ntfy server base URL (default: https://ntfy.sh)
      --ntfy-token     Bearer token for ntfy auth (or set NTFY_TOKEN env var)
  -i, --item-name      Name to include in notification titles/messages
  -d, --delete-after   Delete downloaded files after a successful upload
  -h, --help           Show this help message

Examples:
  grab.sh -l "https://example.com/file.mkv" -r gdrive -u "Incoming" -n "my-topic" -i "Movie Night"
  grab.sh --link "https://example.com/file.zip" --remote myremote --upload-dir "Backups/zips" --ntfy-topic "alerts" --delete-after --item-name "Backup Zip"
EOF
}

DOWNLOAD_LINK=""
RCLONE_REMOTE=""
UPLOAD_DIR=""
NTFY_TOPIC=""
NTFY_SERVER="https://ntfy.sh"
NTFY_TOKEN="${NTFY_TOKEN:-}"
ITEM_NAME=""
DELETE_AFTER="false"
CURRENT_STEP="initializing"
TMP_DIR=""

send_ntfy() {
  local title="$1"
  local message="$2"
  local priority="${3:-default}"
  local tags="${4:-}"

  local url="${NTFY_SERVER%/}/${NTFY_TOPIC}"
  local final_title="$title"
  local final_message="$message"

  if [[ -n "$ITEM_NAME" ]]; then
    final_title="${ITEM_NAME} - ${title}"
    final_message="Item: ${ITEM_NAME}\n${message}"
  fi

  local -a headers
  headers=(
    -H "Title: ${final_title}"
    -H "Priority: ${priority}"
  )

  if [[ -n "$tags" ]]; then
    headers+=( -H "Tags: ${tags}" )
  fi

  if [[ -n "$NTFY_TOKEN" ]]; then
    headers+=( -H "Authorization: Bearer ${NTFY_TOKEN}" )
  fi

  if ! curl -fsS -m 15 -X POST "${headers[@]}" -d "$final_message" "$url" >/dev/null; then
    echo "Warning: failed to publish ntfy notification (${title})." >&2
  fi
}

on_error() {
  local exit_code="$1"
  local line_no="$2"

  send_ntfy \
    "grab.sh failed" \
    "Step: ${CURRENT_STEP}\nExit code: ${exit_code}\nLine: ${line_no}" \
    "high" \
    "x,warning"

  if [[ "$DELETE_AFTER" == "true" && -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--link)
      DOWNLOAD_LINK="${2:-}"
      shift 2
      ;;
    -r|--remote)
      RCLONE_REMOTE="${2:-}"
      shift 2
      ;;
    -u|--upload-dir)
      UPLOAD_DIR="${2:-}"
      shift 2
      ;;
    -n|--ntfy-topic)
      NTFY_TOPIC="${2:-}"
      shift 2
      ;;
    -s|--ntfy-server)
      NTFY_SERVER="${2:-}"
      shift 2
      ;;
    --ntfy-token)
      NTFY_TOKEN="${2:-}"
      shift 2
      ;;
    -i|--item-name)
      ITEM_NAME="${2:-}"
      shift 2
      ;;
    -d|--delete-after)
      DELETE_AFTER="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$DOWNLOAD_LINK" || -z "$RCLONE_REMOTE" || -z "$UPLOAD_DIR" || -z "$NTFY_TOPIC" ]]; then
  echo "Error: missing required arguments." >&2
  usage
  exit 1
fi

for cmd in aria2c rclone mktemp find curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command '$cmd' is not installed or not in PATH." >&2
    exit 1
  fi
done

trap 'on_error $? $LINENO' ERR

TMP_DIR="$(mktemp -d -p "$PWD" "grab.XXXXXX")"
DESTINATION="${RCLONE_REMOTE}:${UPLOAD_DIR%/}"

CURRENT_STEP="job-start"

CURRENT_STEP="download"
echo "Downloading with aria2c..."
send_ntfy "Download started" "Starting aria2c download." "default" "arrow_down"
aria2c \
  --dir "$TMP_DIR" \
  --auto-file-renaming=false \
  --allow-overwrite=true \
  "$DOWNLOAD_LINK"

CURRENT_STEP="verify-download"
if ! find "$TMP_DIR" -mindepth 1 -print -quit >/dev/null 2>&1; then
  send_ntfy "Download empty" "Download directory is empty; upload aborted." "high" "warning"
  echo "Error: download appears empty; nothing to upload." >&2
  exit 1
fi

CURRENT_STEP="upload"
echo "Uploading to ${DESTINATION}..."
send_ntfy "Upload started" "Starting rclone copy to ${DESTINATION}." "default" "arrow_up"
rclone copy "$TMP_DIR" "$DESTINATION" --progress
send_ntfy "Upload complete" "rclone upload finished successfully." "default" "white_check_mark"

if [[ "$DELETE_AFTER" == "true" ]]; then
  CURRENT_STEP="cleanup"
  rm -rf "$TMP_DIR"
  echo "Downloaded files deleted from: $TMP_DIR"
else
  echo "Downloaded files kept at: $TMP_DIR"
fi

CURRENT_STEP="done"
echo "Done. Downloaded from '$DOWNLOAD_LINK' and uploaded to '$DESTINATION'."
send_ntfy "grabar done" "All steps completed successfully." "default" "tada"
