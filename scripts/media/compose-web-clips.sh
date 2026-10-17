#!/usr/bin/env bash
# Encode raw screen recordings (e.g. Maestro startRecording output) into web
# clips: WebM (AV1 via libsvtav1, VP9 when this ffmpeg lacks it) + H.264 MP4
# with +faststart + a WebP poster, each held to a byte budget. Never a GIF.
# Nothing is published unless every clip encoded and every file is within
# budget.
#
# Lifted from budgie-at/budgie@9c3e1f0939e797ed7920ffcd6e23b3a323442d79
# packages/app/fastlane/screenshots/design/compose-web-clips.sh. The VP9, H.264
# and poster settings are budgie's, unchanged; AV1 is added as the preferred
# WebM codec, and paths, length, size, frame rate and budgets are parameters.
#
# Settings, measured by budgie on a synthetic 6.5s 1320x2868 slide-transition
# clip built from 3 real store screenshots: VP9 -crf 38 -b:v 0 -deadline good
# -cpu-used 2 -row-mt 1 at 900 wide is ~244 KB at SSIM 0.989; H.264 -crf 28
# -preset slow -tune animation is ~200 KB at SSIM 0.997; the poster at WebP
# -q 70 is ~43 KB. AV1 was measured the same way (3 real 1320x2868 store
# screenshots, 6.5s with slide transitions, SSIM against the 900-wide
# normalized source): libsvtav1 -crf 42 -preset 6 is 196,127 bytes at SSIM
# 0.9944, against VP9's 246,705 bytes at 0.9927 on the same clip - 20% smaller
# and sharper. Default budgets: 400000 WebM, 400000 MP4, 90000 poster.
#
# Each <scene>.mp4 needs a sibling <scene>.png still for its poster.
#
# Requires ffmpeg with libx264 plus libsvtav1 or libvpx-vp9, ImageMagick 7
# ('magick'), and cwebp unless --webp-encoder magick.

MEDIA_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/media/media-common.sh
. "$MEDIA_DIR/media-common.sh"

usage() {
    cat <<'USAGE'
usage: compose-web-clips.sh --input-dir DIR --output-dir DIR [options]

  --webm-codec auto|av1|vp9     auto prefers AV1 (libsvtav1) and falls back to
                                VP9 (libvpx-vp9); av1/vp9 fail closed when that
                                encoder is missing (default auto)
  --max-seconds N               clip length cap (default 8)
  --fps N                       output frame rate (default 24)
  --width N                     clip and poster width (default 900)
  --poster-height N             poster height (default: width x still aspect)
  --output-template T           output path per clip; '.webm', '.mp4' and
                                '-poster.webp' appended; tokens {dir} {name}
                                {slug} {parent} {grandparent}; {slug} is {name}
                                without a trailing -<n> and then -clip
                                (default {dir}/{name})
  --scenes a,b                  only these clip basenames (each must exist)
  --webp-encoder cwebp|magick   poster encoder (default cwebp)
  --max-webm-bytes N            per-file budget (default 400000)
  --max-mp4-bytes N             per-file budget (default 400000)
  --max-poster-bytes N          per-file budget (default 90000)
  --manifest FILE               write a TSV of published files, bytes, budget
  --dry-run                     print the plan, write nothing
USAGE
}

resolve_webm_codec() {
    case "$1" in
        av1)
            media_ffmpeg_has_encoder libsvtav1 \
                || media_fail "--webm-codec av1 needs an ffmpeg built with libsvtav1 ('ffmpeg -encoders' does not list it). Install one that has it (Homebrew's does), or pass --webm-codec vp9."
            WEBM_CODEC=av1
            ;;
        vp9)
            media_ffmpeg_has_encoder libvpx-vp9 \
                || media_fail "--webm-codec vp9 needs an ffmpeg built with libvpx-vp9."
            WEBM_CODEC=vp9
            ;;
        auto)
            if media_ffmpeg_has_encoder libsvtav1; then
                WEBM_CODEC=av1
            elif media_ffmpeg_has_encoder libvpx-vp9; then
                WEBM_CODEC=vp9
                echo "note: this ffmpeg has no libsvtav1 encoder, so the WebM is VP9 (libvpx-vp9) instead of AV1."
            else
                media_fail "ffmpeg has neither libsvtav1 nor libvpx-vp9, so no WebM can be encoded."
            fi
            ;;
        *) media_fail "unknown --webm-codec '$1'. Use auto, av1 or vp9." ;;
    esac
}

compose_clip() {
    local raw_mp4="$1" webm_out="$2" mp4_out="$3" normalized
    normalized="$WORK_ROOT/normalized-$$-$RANDOM.mp4"
    ffmpeg -nostdin -y -hide_banner -loglevel error -t "$MAX_SECONDS" -i "$raw_mp4" \
        -vf "scale=${WIDTH}:-2:flags=lanczos,fps=${FPS}" -an \
        -c:v libx264 -crf 16 -preset veryfast -pix_fmt yuv420p "$normalized"
    if [ "$WEBM_CODEC" = av1 ]; then
        SVT_LOG=1 ffmpeg -nostdin -y -hide_banner -loglevel error -i "$normalized" \
            -an -c:v libsvtav1 -crf 42 -preset 6 -pix_fmt yuv420p "$webm_out"
    else
        ffmpeg -nostdin -y -hide_banner -loglevel error -i "$normalized" \
            -an -c:v libvpx-vp9 -crf 38 -b:v 0 -deadline good -cpu-used 2 -row-mt 1 -pix_fmt yuv420p "$webm_out"
    fi
    ffmpeg -nostdin -y -hide_banner -loglevel error -i "$normalized" \
        -an -c:v libx264 -profile:v high -crf 28 -preset slow -tune animation -pix_fmt yuv420p -movflags +faststart "$mp4_out"
    rm -f "$normalized"
}

encode_poster() {
    local src="$1" out="$2" height="$POSTER_HEIGHT" still_w still_h resized
    if [ -z "$height" ]; then
        still_w="$(magick identify -format "%w" "$src")"
        still_h="$(magick identify -format "%h" "$src")"
        height="$(awk -v w="$WIDTH" -v sw="$still_w" -v sh="$still_h" 'BEGIN { printf "%d", w * sh / sw + 0.5 }')"
    fi
    resized="$WORK_ROOT/poster-$$-$RANDOM.png"
    magick "$src" -resize "${WIDTH}x${height}!" "$resized"
    if [ "$WEBP_ENCODER" = cwebp ]; then
        cwebp -quiet -q 70 "$resized" -o "$out"
    else
        magick "$resized" -quality 70 "$out"
    fi
    rm -f "$resized"
}

main() {
    set -euo pipefail
    local template='{dir}/{name}' rel name slug base poster count=0 matched='' codec=auto
    local max_webm=400000 max_mp4=400000 max_poster=90000
    MAX_SECONDS=8
    FPS=24
    WIDTH=900
    POSTER_HEIGHT=''
    WEBP_ENCODER=cwebp
    MEDIA_INPUT_DIR=''
    MEDIA_OUTPUT_DIR=''
    MEDIA_SCENES=''
    MEDIA_MANIFEST=''
    MEDIA_DRY_RUN=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --input-dir) media_require_value "$@"; MEDIA_INPUT_DIR="$2"; shift 2 ;;
            --output-dir) media_require_value "$@"; MEDIA_OUTPUT_DIR="$2"; shift 2 ;;
            --webm-codec) media_require_value "$@"; codec="$2"; shift 2 ;;
            --max-seconds) media_require_value "$@"; MAX_SECONDS="$2"; shift 2 ;;
            --fps) media_require_value "$@"; FPS="$2"; shift 2 ;;
            --width) media_require_value "$@"; WIDTH="$2"; shift 2 ;;
            --poster-height) media_require_value "$@"; POSTER_HEIGHT="$2"; shift 2 ;;
            --output-template) media_require_value "$@"; template="$2"; shift 2 ;;
            --scenes) media_require_value "$@"; MEDIA_SCENES="$2"; shift 2 ;;
            --webp-encoder) media_require_value "$@"; WEBP_ENCODER="$2"; shift 2 ;;
            --max-webm-bytes) media_require_value "$@"; max_webm="$2"; shift 2 ;;
            --max-mp4-bytes) media_require_value "$@"; max_mp4="$2"; shift 2 ;;
            --max-poster-bytes) media_require_value "$@"; max_poster="$2"; shift 2 ;;
            --manifest) media_require_value "$@"; MEDIA_MANIFEST="$2"; shift 2 ;;
            --dry-run) MEDIA_DRY_RUN=1; shift ;;
            -h | --help) usage; return 0 ;;
            *) media_fail "unknown argument '$1'. See --help." ;;
        esac
    done

    media_require_dirs
    media_require_positive_int --max-seconds "$MAX_SECONDS"
    media_require_positive_int --fps "$FPS"
    media_require_positive_int --width "$WIDTH"
    [ -z "$POSTER_HEIGHT" ] || media_require_positive_int --poster-height "$POSTER_HEIGHT"
    media_require_positive_int --max-webm-bytes "$max_webm"
    media_require_positive_int --max-mp4-bytes "$max_mp4"
    media_require_positive_int --max-poster-bytes "$max_poster"
    media_validate_template "$template"

    media_require_ffmpeg
    media_ffmpeg_has_encoder libx264 \
        || media_fail "ffmpeg has no libx264 encoder ('ffmpeg -encoders' does not list it), so no H.264 MP4 can be encoded. Install an ffmpeg built with libx264."
    resolve_webm_codec "$codec"
    media_require_magick
    media_require_webp_encoder "$WEBP_ENCODER"
    media_init_work

    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        name="$(basename "$rel" .mp4)"
        media_scene_selected "$name" || continue
        matched="$matched$name
"
        poster="$MEDIA_INPUT_DIR/${rel%.mp4}.png"
        [ -f "$poster" ] || media_fail "missing poster capture $poster for clip '$name'"
        slug="$(printf '%s\n' "$name" | sed -E 's/-[0-9]+$//; s/-clip$//')"
        base="$(media_render_template "$template" "$rel" "$slug")"
        media_claim_output "$base"
        count=$((count + 1))
        if [ "$MEDIA_DRY_RUN" -eq 1 ]; then
            echo "would write $MEDIA_OUTPUT_DIR/$base.webm $MEDIA_OUTPUT_DIR/$base.mp4 $MEDIA_OUTPUT_DIR/$base-poster.webp"
            continue
        fi
        mkdir -p "$(dirname "$MEDIA_STAGE/$base")"
        compose_clip "$MEDIA_INPUT_DIR/$rel" "$MEDIA_STAGE/$base.webm" "$MEDIA_STAGE/$base.mp4"
        encode_poster "$poster" "$MEDIA_STAGE/$base-poster.webp"
        media_budget "$MEDIA_STAGE/$base.webm" "$max_webm"
        media_budget "$MEDIA_STAGE/$base.mp4" "$max_mp4"
        media_budget "$MEDIA_STAGE/$base-poster.webp" "$max_poster"
        echo "composed $base.webm ($WEBM_CODEC) $base.mp4 $base-poster.webp"
    done <<EOF
$(media_list_inputs "$MEDIA_INPUT_DIR" mp4)
EOF

    media_check_scenes_found "$matched"
    media_publish "$count" clip
}

main "$@"
