#!/usr/bin/env bash
# Frame raw device captures in fastlane frameit's real device frames.
#
# Source it for the framing primitives (resolve_frameit_frames_dir,
# resolve_device_frames, frame_device_select, frame_capture,
# frame_device_compose) and lay the framed device out yourself - captions and
# store copy stay app-side. Run it to frame every PNG under --input-dir onto a
# canvas of the capture's own pixel size (what App Store Connect slot matching
# keys on) or the frame's native size, over a transparent or plate background.
#
# Lifted from budgie-at/budgie@9c3e1f0939e797ed7920ffcd6e23b3a323442d79
# packages/app/fastlane/screenshots/design/frame-device.sh; frame_capture is
# byte-for-byte the same algorithm both budgie and vitalyiegorov/suuudokuuu
# ship, and tests/compose-media_test.sh guards that pixel for pixel.
#
# Requires ImageMagick 7 ('magick') and frameit's frame assets
# ('fastlane frameit download_frames', cached at ~/.fastlane/frameit/latest).

# shellcheck disable=SC2034 # IPHONE_*/IPAD_*/DEVICE_* are this library's interface to the scripts that source it.
FRAME_DEVICE_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/media/media-common.sh
. "$FRAME_DEVICE_LIB_DIR/media-common.sh"

IPHONE_FRAME_NAME="${IPHONE_FRAME_NAME:-Apple iPhone 16 Pro Max Black Titanium.png}"
IPAD_FRAME_NAME="${IPAD_FRAME_NAME:-Apple iPad Pro (12.9-inch) (4th generation) Space Gray.png}"

# Measured on frameit's assets by flood-filling the PNG alpha channel and
# cross-checked against frameit's offsets.json. The 16 Pro Max Black Titanium
# panel is the 6.9" store slot (offsets.json gives 16 and 17 Pro Max the same
# +75+66 at 1320 wide); the 12.9" 4th-gen iPad Pro is the closest frameit asset
# to the 13" M4, resized ~1% into the capture.
IPHONE_DEVICE_SLUG='iphone-17-pro-max'
IPHONE_FRAME_CUTOUT='75,66,1320,2868'
IPAD_DEVICE_SLUG='ipad-pro-13-inch-m4'
IPAD_FRAME_CUTOUT='96,102,2048,2732'

# resolve_frameit_frames_dir — sets FRAMES_DIR from FRAMEIT_FRAMES_DIR, else
# the fastlane cache (current, then pre-move location).
resolve_frameit_frames_dir() {
    local candidate
    FRAMES_DIR=''
    if [ -n "${FRAMEIT_FRAMES_DIR:-}" ]; then
        [ -d "$FRAMEIT_FRAMES_DIR" ] || media_fail "frameit frames directory '$FRAMEIT_FRAMES_DIR' does not exist."
        FRAMES_DIR="$FRAMEIT_FRAMES_DIR"
        return 0
    fi
    for candidate in "$HOME/.fastlane/frameit/latest" "$HOME/.frameit/latest"; do
        if [ -d "$candidate" ]; then
            FRAMES_DIR="$candidate"
            return 0
        fi
    done
    media_fail "fastlane frameit device frames not found. Run 'fastlane frameit download_frames' first (downloads to ~/.fastlane/frameit/latest), or point FRAMEIT_FRAMES_DIR / --frames-dir at a copy."
}

frame_device_require_frame() {
    [ -f "$1" ] || media_fail "missing frame asset '$1' - re-run 'fastlane frameit download_frames'."
}

# resolve_device_frames — budgie's interface: IPHONE_*/IPAD_* frame paths and
# portrait cutouts for both devices.
resolve_device_frames() {
    IPHONE_FRAME="$FRAMES_DIR/$IPHONE_FRAME_NAME"
    IFS=, read -r IPHONE_CUTOUT_X IPHONE_CUTOUT_Y IPHONE_CUTOUT_W IPHONE_CUTOUT_H <<EOF
$IPHONE_FRAME_CUTOUT
EOF
    IPAD_FRAME="$FRAMES_DIR/$IPAD_FRAME_NAME"
    IFS=, read -r IPAD_CUTOUT_X IPAD_CUTOUT_Y IPAD_CUTOUT_W IPAD_CUTOUT_H <<EOF
$IPAD_FRAME_CUTOUT
EOF
    frame_device_require_frame "$IPHONE_FRAME"
    frame_device_require_frame "$IPAD_FRAME"
}

frame_device_parse_cutout() {
    if ! printf '%s\n' "$1" | grep -Eq '^[0-9]+,[0-9]+,[1-9][0-9]*,[1-9][0-9]*$'; then
        media_fail "cutout '$1' must be X,Y,W,H in frame pixels."
    fi
}

# frame_device_select <iphone|ipad> <portrait|landscape> — sets DEVICE_FRAME,
# DEVICE_SLUG and DEVICE_CUTOUT_X/Y/W/H. FRAME_DEVICE_FRAME and
# FRAME_DEVICE_CUTOUT (X,Y,W,H) replace the frameit asset with your own. A
# landscape frame is the portrait one rotated 90 degrees clockwise into
# WORK_ROOT, with its cutout rotated alongside rather than re-measured.
frame_device_select() {
    local device="$1" orientation="$2" frame cutout frame_w frame_h x y w h
    FRAMES_DIR="${FRAMES_DIR:-}"
    case "$device" in
        iphone)
            DEVICE_SLUG="$IPHONE_DEVICE_SLUG"
            frame="$FRAMES_DIR/$IPHONE_FRAME_NAME"
            cutout="$IPHONE_FRAME_CUTOUT"
            ;;
        ipad)
            DEVICE_SLUG="$IPAD_DEVICE_SLUG"
            frame="$FRAMES_DIR/$IPAD_FRAME_NAME"
            cutout="$IPAD_FRAME_CUTOUT"
            ;;
        *) media_fail "unknown device '$device'. Use iphone or ipad." ;;
    esac
    if [ -n "${FRAME_DEVICE_FRAME:-}" ]; then
        frame="$FRAME_DEVICE_FRAME"
        cutout="$FRAME_DEVICE_CUTOUT"
    fi
    frame_device_require_frame "$frame"
    frame_device_parse_cutout "$cutout"
    IFS=, read -r x y w h <<EOF
$cutout
EOF
    frame_w="$(magick identify -format "%w" "$frame")"
    frame_h="$(magick identify -format "%h" "$frame")"
    if [ $((x + w)) -gt "$frame_w" ] || [ $((y + h)) -gt "$frame_h" ]; then
        media_fail "cutout $cutout lies outside the ${frame_w}x${frame_h} frame '$frame' - the frame asset changed, re-measure the cutout."
    fi
    case "$orientation" in
        portrait)
            DEVICE_FRAME="$frame"
            DEVICE_CUTOUT_X="$x"
            DEVICE_CUTOUT_Y="$y"
            DEVICE_CUTOUT_W="$w"
            DEVICE_CUTOUT_H="$h"
            ;;
        landscape)
            [ -n "${WORK_ROOT:-}" ] || media_fail 'frame_device_select needs WORK_ROOT set for a landscape frame.'
            DEVICE_FRAME="$WORK_ROOT/$device-landscape-frame.png"
            if [ ! -f "$DEVICE_FRAME" ]; then
                magick "$frame" -rotate 90 -define png:color-type=6 -depth 8 "$DEVICE_FRAME"
            fi
            DEVICE_CUTOUT_X=$((frame_h - y - h))
            DEVICE_CUTOUT_Y="$x"
            DEVICE_CUTOUT_W="$h"
            DEVICE_CUTOUT_H="$w"
            ;;
        *) media_fail "unknown orientation '$orientation'. Use portrait or landscape." ;;
    esac
}

# frame_capture <src> <frame> <x> <y> <w> <h> <out> — resizes the capture into
# the frame's transparent cutout, clips it to the opening the bezel encloses
# (the cutout's bounding box overlaps the frame's transparent outer corners),
# and layers the frame on top. Output is at the frame's native size. Needs
# WORK_ROOT for its scratch mask.
frame_capture() {
    local src="$1" frame_file="$2" cutout_x="$3" cutout_y="$4" cutout_w="$5" cutout_h="$6" out="$7"
    local frame_native_w frame_native_h cutout_mask
    frame_native_w="$(magick identify -format "%w" "$frame_file")"
    frame_native_h="$(magick identify -format "%h" "$frame_file")"
    cutout_mask="$WORK_ROOT/cutout-mask-$$-$RANDOM.png"
    magick "$frame_file" -alpha extract -fuzz 50% -fill white -floodfill +0+0 black -negate \
        \( -size "${frame_native_w}x${frame_native_h}" xc:black -fill white \
        -draw "rectangle ${cutout_x},${cutout_y} $((cutout_x + cutout_w - 1)),$((cutout_y + cutout_h - 1))" \) \
        -compose Multiply -composite -define png:color-type=0 -depth 8 "$cutout_mask"
    magick -size "${frame_native_w}x${frame_native_h}" xc:none \
        \( "$src" -resize "${cutout_w}x${cutout_h}!" \) -geometry "+${cutout_x}+${cutout_y}" -compose Over -composite \
        "$cutout_mask" -compose CopyOpacity -composite \
        "$frame_file" -compose Over -composite \
        -define png:color-type=6 -depth 8 "$out"
    rm -f "$cutout_mask"
}

frame_device_validate_background() {
    case "$1" in
        transparent) return 0 ;;
    esac
    if ! printf '%s\n' "$1" | grep -Eq '^#[0-9A-Fa-f]{6}(-#[0-9A-Fa-f]{6})?$'; then
        media_fail "background '$1' is not 'transparent', '#RRGGBB' or a top-to-bottom '#RRGGBB-#RRGGBB' gradient."
    fi
}

# frame_device_plate <background> <w> <h> <out> — the opaque plate under the
# device: a solid colour or a top-to-bottom gradient.
frame_device_plate() {
    local background="$1" w="$2" h="$3" out="$4"
    case "$background" in
        *-*) magick -size "${w}x${h}" "gradient:${background}" -define png:color-type=2 -depth 8 "$out" ;;
        *) magick -size "${w}x${h}" "xc:${background}" -define png:color-type=2 -depth 8 "$out" ;;
    esac
}

# frame_device_compose <src> <out> <device> <orientation> <canvas> <background> <fit>
#   orientation: portrait | landscape | auto (landscape when the capture is wider than tall)
#   canvas: capture (the capture's own pixel size) | frame (the frame's native size)
#   fit: fraction of the capture canvas the framed device is contained in (capture canvas only)
frame_device_compose() {
    local src="$1" out="$2" device="$3" orientation="$4" canvas="$5" background="$6" fit="$7"
    local canvas_w canvas_h box_w box_h framed placed plate
    canvas_w="$(magick identify -format "%w" "$src")"
    canvas_h="$(magick identify -format "%h" "$src")"
    if [ "$orientation" = auto ]; then
        orientation=portrait
        [ "$canvas_w" -gt "$canvas_h" ] && orientation=landscape
    fi
    frame_device_select "$device" "$orientation"

    framed="$WORK_ROOT/framed-$$-$RANDOM.png"
    frame_capture "$src" "$DEVICE_FRAME" "$DEVICE_CUTOUT_X" "$DEVICE_CUTOUT_Y" "$DEVICE_CUTOUT_W" "$DEVICE_CUTOUT_H" "$framed"

    case "$canvas" in
        frame)
            placed="$framed"
            canvas_w="$(magick identify -format "%w" "$framed")"
            canvas_h="$(magick identify -format "%h" "$framed")"
            ;;
        capture)
            box_w="$(awk -v n="$canvas_w" -v f="$fit" 'BEGIN { printf "%d", n * f }')"
            box_h="$(awk -v n="$canvas_h" -v f="$fit" 'BEGIN { printf "%d", n * f }')"
            placed="$WORK_ROOT/contained-$$-$RANDOM.png"
            magick -size "${canvas_w}x${canvas_h}" xc:none \
                \( "$framed" -resize "${box_w}x${box_h}" \) \
                -gravity center -compose Over -composite \
                -define png:color-type=6 -depth 8 "$placed"
            ;;
        *) media_fail "unknown canvas '$canvas'. Use capture or frame." ;;
    esac

    if [ "$background" = transparent ]; then
        cp "$placed" "$out"
    else
        plate="$WORK_ROOT/plate-$$-$RANDOM.png"
        frame_device_plate "$background" "$canvas_w" "$canvas_h" "$plate"
        magick "$plate" "$placed" -compose Over -composite \
            -alpha off -define png:color-type=2 -depth 8 "$out"
        rm -f "$plate"
    fi
    rm -f "$framed" "$placed"
}

frame_device_usage() {
    cat <<'USAGE'
usage: frame-device.sh --input-dir DIR --output-dir DIR [options]

  --device iphone|ipad          frameit device (default iphone)
  --orientation auto|portrait|landscape
                                landscape rotates the portrait frame (default auto)
  --canvas capture|frame        output at the capture's pixel size or the
                                frame's native size (default capture)
  --background transparent|#RRGGBB|#RRGGBB-#RRGGBB
                                plate behind the device (default transparent)
  --fit F                       fraction (0,1] of the capture canvas the device
                                is contained in (default 1)
  --output-template T           output path per capture, '.png' appended;
                                tokens {dir} {name} {slug} {parent} {grandparent}
                                (default {dir}/{name})
  --scenes a,b                  only these capture basenames (each must exist)
  --frames-dir DIR              frameit frames directory (default the fastlane cache)
  --frame FILE --cutout X,Y,W,H your own frame PNG and its measured cutout
  --manifest FILE               write a TSV of published files and byte sizes
  --dry-run                     print the plan, write nothing
USAGE
}

frame_device_main() {
    set -euo pipefail
    local device=iphone orientation=auto canvas=capture background=transparent fit=1
    local template='{dir}/{name}' rel name slug out count=0 matched=''
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
            --device) media_require_value "$@"; device="$2"; shift 2 ;;
            --orientation) media_require_value "$@"; orientation="$2"; shift 2 ;;
            --canvas) media_require_value "$@"; canvas="$2"; shift 2 ;;
            --background) media_require_value "$@"; background="$2"; shift 2 ;;
            --fit) media_require_value "$@"; fit="$2"; shift 2 ;;
            --output-template) media_require_value "$@"; template="$2"; shift 2 ;;
            --scenes) media_require_value "$@"; MEDIA_SCENES="$2"; shift 2 ;;
            --frames-dir) media_require_value "$@"; FRAMEIT_FRAMES_DIR="$2"; shift 2 ;;
            --frame) media_require_value "$@"; FRAME_DEVICE_FRAME="$2"; shift 2 ;;
            --cutout) media_require_value "$@"; FRAME_DEVICE_CUTOUT="$2"; shift 2 ;;
            --manifest) media_require_value "$@"; MEDIA_MANIFEST="$2"; shift 2 ;;
            --dry-run) MEDIA_DRY_RUN=1; shift ;;
            -h | --help) frame_device_usage; return 0 ;;
            *) media_fail "unknown argument '$1'. See --help." ;;
        esac
    done

    media_require_dirs
    case "$device" in
        iphone | ipad) ;;
        *) media_fail "unknown device '$device'. Use iphone or ipad." ;;
    esac
    case "$orientation" in
        auto | portrait | landscape) ;;
        *) media_fail "unknown orientation '$orientation'. Use auto, portrait or landscape." ;;
    esac
    case "$canvas" in
        capture | frame) ;;
        *) media_fail "unknown canvas '$canvas'. Use capture or frame." ;;
    esac
    frame_device_validate_background "$background"
    media_require_fraction --fit "$fit"
    media_validate_template "$template"
    if [ -n "$FRAME_DEVICE_FRAME" ] && [ -z "$FRAME_DEVICE_CUTOUT" ]; then
        media_fail "--frame needs --cutout X,Y,W,H: the screen cutout is measured per frame asset."
    fi
    if [ -z "$FRAME_DEVICE_FRAME" ] && [ -n "$FRAME_DEVICE_CUTOUT" ]; then
        media_fail '--cutout only applies to a custom --frame.'
    fi

    media_require_magick
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
        out="$(media_render_template "$template" "$rel" "$slug").png"
        count=$((count + 1))
        if [ "$MEDIA_DRY_RUN" -eq 1 ]; then
            echo "would write $MEDIA_OUTPUT_DIR/$out"
            continue
        fi
        mkdir -p "$(dirname "$MEDIA_STAGE/$out")"
        frame_device_compose "$MEDIA_INPUT_DIR/$rel" "$MEDIA_STAGE/$out" "$device" "$orientation" "$canvas" "$background" "$fit"
        printf '%s\t%s\t-\n' "$out" "$(media_bytes "$MEDIA_STAGE/$out")" >> "$MEDIA_WORK/manifest.tsv"
        echo "framed $out"
    done <<EOF
$(media_list_inputs "$MEDIA_INPUT_DIR" png)
EOF

    media_check_scenes_found "$matched"
    media_publish "$count" capture
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    frame_device_main "$@"
fi
