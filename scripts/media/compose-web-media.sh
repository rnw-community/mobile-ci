#!/usr/bin/env bash
# Compose raw PNG captures into framed web stills: AVIF + WebP at a fixed 2x
# size, each held to a byte budget. Nothing is published unless every capture
# composed and every file is within budget.
#
# Lifted from budgie-at/budgie@9c3e1f0939e797ed7920ffcd6e23b3a323442d79
# packages/app/fastlane/screenshots/design/compose-web-media.sh. The pipeline
# (frame_capture -> contain on a capture-sized canvas -> resize -> encode) and
# the encoder settings are unchanged; paths, size, device, background,
# encoder choice and budgets are parameters.
#
# Encoder settings, measured by budgie on 3 real framed store screenshots
# downscaled to 900 wide (SSIM against the source PNG): avifenc -s 4 --min 0
# --max 63 -a end-usage=q -a cq-level=30 -a tune=ssim averages 26,982 bytes at
# SSIM 0.998; WebP -q 75 -m 6 averages 40,553 bytes at SSIM 0.996. The default
# budgets (60000 AVIF, 90000 WebP) leave ~2.2x headroom over those averages.
#
# Requires ImageMagick 7 ('magick'), avifenc (libavif), and cwebp unless
# --webp-encoder magick; plus frameit's frames ('fastlane frameit
# download_frames').

MEDIA_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/media/frame-device.sh
. "$MEDIA_DIR/frame-device.sh"

usage() {
    cat <<'USAGE'
usage: compose-web-media.sh --input-dir DIR --output-dir DIR [options]

  --device iphone|ipad          frameit device (default iphone)
  --orientation auto|portrait|landscape    (default auto)
  --background transparent|#RRGGBB|#RRGGBB-#RRGGBB   (default transparent)
  --width N                     output width in pixels (default 900)
  --height N                    output height (default: width x capture aspect)
  --output-template T           output path per capture, '.avif'/'.webp'
                                appended; tokens {dir} {name} {slug} {parent}
                                {grandparent}; {slug} is {name} without a
                                trailing -<n> (default {dir}/{name}@2x)
  --scenes a,b                  only these capture basenames (each must exist)
  --webp-encoder cwebp|magick   (default cwebp)
  --max-avif-bytes N            per-file budget (default 60000)
  --max-webp-bytes N            per-file budget (default 90000)
  --frames-dir DIR | --frame FILE --cutout X,Y,W,H
  --manifest FILE               write a TSV of published files, bytes, budget
  --dry-run                     print the plan, write nothing
USAGE
}

encode_still() {
    local src="$1" avif_out="$2" webp_out="$3"
    avifenc -s 4 --min 0 --max 63 -a end-usage=q -a cq-level=30 -a tune=ssim "$src" "$avif_out" >/dev/null
    if [ "$WEBP_ENCODER" = cwebp ]; then
        cwebp -quiet -q 75 -m 6 "$src" -o "$webp_out"
    else
        magick "$src" -quality 75 -define webp:method=6 "$webp_out"
    fi
}

compose_still() {
    local src="$1" avif_out="$2" webp_out="$3" canvas_w canvas_h height contained final
    canvas_w="$(magick identify -format "%w" "$src")"
    canvas_h="$(magick identify -format "%h" "$src")"
    height="$HEIGHT"
    if [ -z "$height" ]; then
        height="$(awk -v w="$WIDTH" -v cw="$canvas_w" -v ch="$canvas_h" 'BEGIN { printf "%d", w * ch / cw + 0.5 }')"
    fi
    contained="$WORK_ROOT/contained-$$-$RANDOM.png"
    frame_device_compose "$src" "$contained" "$DEVICE" "$ORIENTATION" capture "$BACKGROUND" 1
    final="$WORK_ROOT/final-$$-$RANDOM.png"
    magick "$contained" -resize "${WIDTH}x${height}!" \
        -define png:color-type=6 -depth 8 "$final"
    encode_still "$final" "$avif_out" "$webp_out"
    rm -f "$contained" "$final"
}

main() {
    set -euo pipefail
    local template='{dir}/{name}@2x' rel name slug base count=0 matched=''
    local max_avif=60000 max_webp=90000
    DEVICE=iphone
    ORIENTATION=auto
    BACKGROUND=transparent
    WIDTH=900
    HEIGHT=''
    WEBP_ENCODER=cwebp
    MEDIA_INPUT_DIR=''
    MEDIA_OUTPUT_DIR=''
    MEDIA_SCENES=''
    MEDIA_MANIFEST=''
    MEDIA_DRY_RUN=0
    FRAME_DEVICE_FRAME=''
    FRAME_DEVICE_CUTOUT=''

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --input-dir) media_require_value "$@"; MEDIA_INPUT_DIR="$2"; shift 2 ;;
            --output-dir) media_require_value "$@"; MEDIA_OUTPUT_DIR="$2"; shift 2 ;;
            --device) media_require_value "$@"; DEVICE="$2"; shift 2 ;;
            --orientation) media_require_value "$@"; ORIENTATION="$2"; shift 2 ;;
            --background) media_require_value "$@"; BACKGROUND="$2"; shift 2 ;;
            --width) media_require_value "$@"; WIDTH="$2"; shift 2 ;;
            --height) media_require_value "$@"; HEIGHT="$2"; shift 2 ;;
            --output-template) media_require_value "$@"; template="$2"; shift 2 ;;
            --scenes) media_require_value "$@"; MEDIA_SCENES="$2"; shift 2 ;;
            --webp-encoder) media_require_value "$@"; WEBP_ENCODER="$2"; shift 2 ;;
            --max-avif-bytes) media_require_value "$@"; max_avif="$2"; shift 2 ;;
            --max-webp-bytes) media_require_value "$@"; max_webp="$2"; shift 2 ;;
            --frames-dir) media_require_value "$@"; FRAMEIT_FRAMES_DIR="$2"; shift 2 ;;
            --frame) media_require_value "$@"; FRAME_DEVICE_FRAME="$2"; shift 2 ;;
            --cutout) media_require_value "$@"; FRAME_DEVICE_CUTOUT="$2"; shift 2 ;;
            --manifest) media_require_value "$@"; MEDIA_MANIFEST="$2"; shift 2 ;;
            --dry-run) MEDIA_DRY_RUN=1; shift ;;
            -h | --help) usage; return 0 ;;
            *) media_fail "unknown argument '$1'. See --help." ;;
        esac
    done

    media_require_dirs
    case "$DEVICE" in
        iphone | ipad) ;;
        *) media_fail "unknown device '$DEVICE'. Use iphone or ipad." ;;
    esac
    case "$ORIENTATION" in
        auto | portrait | landscape) ;;
        *) media_fail "unknown orientation '$ORIENTATION'. Use auto, portrait or landscape." ;;
    esac
    frame_device_validate_background "$BACKGROUND"
    media_require_positive_int --width "$WIDTH"
    [ -z "$HEIGHT" ] || media_require_positive_int --height "$HEIGHT"
    media_require_positive_int --max-avif-bytes "$max_avif"
    media_require_positive_int --max-webp-bytes "$max_webp"
    media_validate_template "$template"
    if [ -n "$FRAME_DEVICE_FRAME" ] && [ -z "$FRAME_DEVICE_CUTOUT" ]; then
        media_fail "--frame needs --cutout X,Y,W,H: the screen cutout is measured per frame asset."
    fi

    media_require_magick
    media_require_avifenc
    media_require_webp_encoder "$WEBP_ENCODER"
    if [ -z "$FRAME_DEVICE_FRAME" ]; then
        resolve_frameit_frames_dir
    fi
    media_init_work

    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        name="$(basename "$rel" .png)"
        media_scene_selected "$name" || continue
        matched="$matched$name
"
        slug="$(printf '%s\n' "$name" | sed -E 's/-[0-9]+$//')"
        base="$(media_render_template "$template" "$rel" "$slug")"
        media_claim_output "$base"
        count=$((count + 1))
        if [ "$MEDIA_DRY_RUN" -eq 1 ]; then
            echo "would write $MEDIA_OUTPUT_DIR/$base.avif $MEDIA_OUTPUT_DIR/$base.webp"
            continue
        fi
        mkdir -p "$(dirname "$MEDIA_STAGE/$base")"
        compose_still "$MEDIA_INPUT_DIR/$rel" "$MEDIA_STAGE/$base.avif" "$MEDIA_STAGE/$base.webp"
        media_budget "$MEDIA_STAGE/$base.avif" "$max_avif"
        media_budget "$MEDIA_STAGE/$base.webp" "$max_webp"
        echo "composed $base.avif $base.webp"
    done <<EOF
$(media_list_inputs "$MEDIA_INPUT_DIR" png)
EOF

    media_check_scenes_found "$matched"
    media_publish "$count" capture
}

main "$@"
