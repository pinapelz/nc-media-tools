#!/usr/bin/env bash
set -Eeuo pipefail

DELETE_ORIGINALS=false
MEDIA_EXTS=("mp4" "mkv" "mov" "avi" "webm" "m4v")
SEARCH_DIR="."
STYLE="FontName=Arial,FontSize=18,PrimaryColour=&HFFFFFF&,BackColour=&H000000&,BorderStyle=3,Outline=1,Shadow=0,MarginV=10,Alignment=2"

usage() {
cat <<EOF
Usage:
  $(basename "$0") [DIRECTORY] [options]

Burn subtitles into every supported media file that has a matching
.srt or .vtt file with the same basename.

Examples:
  $(basename "$0")
  $(basename "$0") ~/Videos
  $(basename "$0") /mnt/media --delete-originals
  $(basename "$0") ~/Videos --style "FontName=Roboto,FontSize=30"

Options:
  --delete-originals
      Delete original media and subtitle after successful conversion.

  --style "ASS_STYLE"
      Subtitle styling passed to FFmpeg's force_style.

  --ext "mp4 mkv mov"
      Space-separated list of media extensions.

  -h, --help
      Show this help.

EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete-originals)
            DELETE_ORIGINALS=true
            shift
            ;;

        --style)
            STYLE="$2"
            shift 2
            ;;

        --ext)
            read -ra MEDIA_EXTS <<< "$2"
            shift 2
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        -*)
            echo "Unknown option: $1"
            exit 1
            ;;

        *)
            if [[ "$SEARCH_DIR" != "." ]]; then
                echo "Only one directory may be specified."
                exit 1
            fi
            SEARCH_DIR="$1"
            shift
            ;;
    esac
done

if [[ ! -d "$SEARCH_DIR" ]]; then
    echo "Directory does not exist: $SEARCH_DIR"
    exit 1
fi

command -v ffmpeg >/dev/null || {
    echo "ffmpeg not found."
    exit 1
}

escape_path() {
    printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

for ext in "${MEDIA_EXTS[@]}"; do
    while IFS= read -r -d '' media; do

        dir=$(dirname "$media")
        filename=$(basename "$media")
        base="${filename%.*}"
        extension="${filename##*.}"

        subtitle=""

        shopt -s nullglob nocaseglob


        for candidate in \
            "$dir/$base.srt" \
            "$dir/$base.vtt" \
            "$dir/$base".*.srt \
            "$dir/$base".*.vtt; do
            [[ -e "$candidate" ]] || continue
            subtitle="$candidate"
            break
        done

        shopt -u nullglob nocaseglob

        [[ -n "$subtitle" ]] || continue

        output="$dir/${base}_subbed.${extension}"

        echo
        echo "=================================="
        echo "Media:    $media"
        echo "Subtitle: $subtitle"
        echo "Output:   $output"
        echo "=================================="

        escaped_sub=$(escape_path "$subtitle")

        ffmpeg \
            -hide_banner \
            -y \
            -i "$media" \
            -vf "subtitles='${escaped_sub}':force_style='${STYLE}'" \
            -c:v libx264 \
            -preset medium \
            -crf 18 \
            -c:a copy \
            "$output" \
            < /dev/null

        if [[ $? -eq 0 ]]; then
            echo "✓ Finished"

            if $DELETE_ORIGINALS; then
                rm -f "$media" "$subtitle"
                echo "Deleted originals."
            fi
        else
            echo "✗ Failed: $media"
        fi

    done < <(find "$SEARCH_DIR" -type f -iname "*.${ext}" -print0)
done

echo
echo "Done."
