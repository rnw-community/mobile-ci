#!/usr/bin/env bash
# compose-media frames raw captures and encodes web media through the scripts
# under scripts/media. Two kinds of case run here:
#
# - Stubbed cases always run. They put fake magick/avifenc/cwebp/ffmpeg on a
#   sandboxed PATH so preflight, argument validation, template rendering and
#   byte-budget enforcement are exercised without any media toolchain.
# - Real-tool cases need ImageMagick 7, ffmpeg, avifenc and a WebP encoder.
#   Each one skips with an explicit message naming the missing tool; CI's
#   unit-tests job installs all of them so none skip there. These include the
#   pixel-parity guard: the extracted scripts must reproduce budgie's in-repo
#   implementation (fixtures/compose-media/budgie-reference, lifted from
#   budgie-at/budgie@9c3e1f0939e797ed7920ffcd6e23b3a323442d79) exactly.
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/harness.sh"

ACTION="$REPO_ROOT/actions/compose-media/action.yml"
STEP='Compose media'
MEDIA="$REPO_ROOT/scripts/media"
REFERENCE="$REPO_ROOT/fixtures/compose-media/budgie-reference"
IPHONE_FRAME_NAME='Apple iPhone 16 Pro Max Black Titanium.png'
IPAD_FRAME_NAME='Apple iPad Pro (12.9-inch) (4th generation) Space Gray.png'

# COMPOSE_MEDIA_REQUIRE_TOOLS=1 (set by self-test.yml) turns a skip into a
# failure, so CI can never pass by quietly skipping the real-tool cases.
SKIPPED=0
skip_case() {
    if [ "${COMPOSE_MEDIA_REQUIRE_TOOLS:-0}" = 1 ]; then
        case_start "$1"
        fail_case "$2, and COMPOSE_MEDIA_REQUIRE_TOOLS=1 forbids skipping"
        return 0
    fi
    SKIPPED=$((SKIPPED + 1))
    printf 'skip  %s\n      %s\n' "$1" "$2"
}

missing_tool() {
    local tool
    for tool in "$@"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            printf '%s' "$tool"
            return 0
        fi
    done
    return 1
}

# --- sandboxed PATH ---------------------------------------------------------

# sandbox_bin <dir> — a PATH holding only the coreutils the scripts may use, so
# a real magick/ffmpeg on the host can never satisfy a preflight under test.
sandbox_bin() {
    local dir="$1" tool resolved
    mkdir -p "$dir/sandbox"
    for tool in bash sh env find sort mktemp sed awk wc tr dirname basename mkdir rm cp mv cat grep head tail cut ls rmdir touch dd od printf; do
        resolved="$(command -v "$tool" 2>/dev/null || true)"
        case "$resolved" in
            /*) ln -sf "$resolved" "$dir/sandbox/$tool" ;;
        esac
    done
}

# Stub images are text files holding "<W>x<H>"; stub encoders write files of a
# byte size chosen by the case, so budgets are exercised deterministically.
stub_magick() {
    # shellcheck disable=SC2016 # expanded when the stub runs.
    stub "$1" magick '
last=""
for arg in "$@"; do last="$arg"; done
if [ "$1" = identify ]; then
    format="$3"; file="$4"
    dims="$(head -n 1 "$file")"
    w="${dims%x*}"; h="${dims#*x}"
    case "$format" in
        %w) printf "%s" "$w" ;;
        %h) printf "%s" "$h" ;;
        *) printf "%sx%s" "$w" "$h" ;;
    esac
    exit 0
fi
printf "%s\n" "magick $*" >> "${STUB_LOG:-/dev/null}"
out="${last#*:}"
case "$out" in
    *.webp) head -c "${STUB_WEBP_BYTES:-100}" /dev/zero > "$out" ;;
    *) printf "%s\n" "${STUB_IMAGE_DIMS:-1320x2868}" > "$out" ;;
esac'
}

stub_avifenc() {
    # shellcheck disable=SC2016
    stub "$1" avifenc '
last=""
for arg in "$@"; do last="$arg"; done
head -c "${STUB_AVIF_BYTES:-100}" /dev/zero > "$last"'
}

stub_cwebp() {
    # shellcheck disable=SC2016
    stub "$1" cwebp '
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then out="$2"; fi
    shift
done
head -c "${STUB_WEBP_BYTES:-100}" /dev/zero > "$out"'
}

stub_ffmpeg() {
    # shellcheck disable=SC2016
    stub "$1" ffmpeg '
for arg in "$@"; do
    if [ "$arg" = -encoders ]; then
        printf "%b\n" "${STUB_FFMPEG_ENCODERS:- V..... libx264 H.264\n V..... libvpx-vp9 VP9\n V..... libsvtav1 AV1}"
        exit 0
    fi
done
printf "%s\n" "ffmpeg $*" >> "${STUB_LOG:-/dev/null}"
last=""
for arg in "$@"; do last="$arg"; done
case "$last" in
    *.webm) head -c "${STUB_WEBM_BYTES:-100}" /dev/zero > "$last" ;;
    *) head -c "${STUB_MP4_BYTES:-100}" /dev/zero > "$last" ;;
esac'
}

# stub_frames <dir> — a fake frameit cache whose frames carry the real frames'
# pixel dimensions.
stub_frames() {
    local frames="$1/home/.fastlane/frameit/latest"
    mkdir -p "$frames"
    printf '1470x3000\n' > "$frames/$IPHONE_FRAME_NAME"
    printf '2245x2930\n' > "$frames/$IPAD_FRAME_NAME"
}

# stub_media_workspace — every media tool stubbed, a frame cache, and one raw
# iPhone capture at <work>/raw/en/light/home-hero-1.png.
stub_media_workspace() {
    local dir
    dir="$(new_empty_workspace)"
    sandbox_bin "$dir"
    stub_magick "$dir"
    stub_avifenc "$dir"
    stub_cwebp "$dir"
    stub_ffmpeg "$dir"
    stub_frames "$dir"
    mkdir -p "$dir/work/raw/en/light"
    printf '1320x2868\n' > "$dir/work/raw/en/light/home-hero-1.png"
    printf '%s\n' "$dir"
}

# run_script <workspace> <script> [args...] — runs with only the stubs and the
# sandboxed coreutils on PATH. Extra env goes through RUN_ENV (space separated
# KEY=VALUE words).
run_script() {
    local dir="$1" script="$2"
    shift 2
    STEP_STATUS=0
    (
        cd "$dir/work" || exit 1
        # shellcheck disable=SC2086 # RUN_ENV is a deliberate word list.
        env -i PATH="$dir/stub-bin:$dir/sandbox" HOME="$dir/home" TMPDIR="$dir/runner-temp" \
            STUB_LOG="$dir/stub.log" ${RUN_ENV:-} \
            bash "$MEDIA/$script" "$@"
    ) > "$dir/log" 2>&1 || STEP_STATUS=$?
    RUN_ENV=''
    return 0
}

assert_failed() {
    if [ "$STEP_STATUS" -eq 0 ]; then
        fail_case "expected a non-zero exit, got 0: $(cat "$1/log")"
        return 1
    fi
    return 0
}

assert_file() {
    if [ ! -f "$1" ]; then
        fail_case "no file at $1; found: $(find "$(dirname "$(dirname "$1")")" -type f 2>/dev/null | tr '\n' ' ')"
        return 1
    fi
    return 0
}

assert_succeeded() {
    if [ "$STEP_STATUS" -ne 0 ]; then
        fail_case "expected success, got $STEP_STATUS: $(cat "$1/log")"
        return 1
    fi
    return 0
}

# --- action step ------------------------------------------------------------

# action_workspace — the step extracted from action.yml, with the three scripts
# replaced by recorders so the case sees exactly the argv the step built.
action_workspace() {
    local dir name
    dir="$(new_workspace "$ACTION" "$STEP")"
    mkdir -p "$dir/scripts"
    for name in frame-device.sh compose-web-media.sh compose-web-clips.sh; do
        # shellcheck disable=SC2016
        printf '%s\n' 'printf "%s\n" "$(basename "$0")" > "$RECORD_DIR/script"' \
            ': > "$RECORD_DIR/argv"' \
            'for a in "$@"; do printf "%s\n" "$a" >> "$RECORD_DIR/argv"; done' \
            'manifest=""' \
            'while [ "$#" -gt 0 ]; do if [ "$1" = --manifest ]; then manifest="$2"; fi; shift; done' \
            'printf "a.avif\t10\t20\nb.webp\t10\t20\n" > "$manifest"' > "$dir/scripts/$name"
    done
    printf '%s\n' "$dir"
}

run_action() {
    local dir="$1"
    shift
    run_step "$dir" \
        MEDIA_SCRIPTS_DIR="$dir/scripts" \
        RECORD_DIR="$dir" \
        MODE=stills \
        INPUT_DIR=raw \
        OUTPUT_DIR=out \
        DEVICE=iphone \
        ORIENTATION=auto \
        BACKGROUND=transparent \
        CANVAS=capture \
        FIT='' \
        WIDTH='' \
        HEIGHT='' \
        OUTPUT_TEMPLATE='' \
        SCENES='' \
        FRAMES_DIR='' \
        FRAME_FILE='' \
        FRAME_CUTOUT='' \
        WEBP_ENCODER='' \
        WEBM_CODEC='' \
        MAX_SECONDS='' \
        FPS='' \
        MAX_AVIF_BYTES='' \
        MAX_WEBP_BYTES='' \
        MAX_WEBM_BYTES='' \
        MAX_MP4_BYTES='' \
        MAX_POSTER_BYTES='' \
        "$@"
}

argv_of() {
    tr '\n' ' ' < "$1/argv" | sed 's/ $//'
}

case_start 'action: an unknown mode fails closed before any script runs'
dir="$(action_workspace)"
run_action "$dir" MODE=gif
if [ "$STEP_STATUS" -ne 0 ] && [ ! -f "$dir/script" ]; then
    assert_contains "$(cat "$dir/log")" "Unsupported mode 'gif'" 'error names the mode' && pass_case
else
    fail_case "status $STEP_STATUS, script $(cat "$dir/script" 2>/dev/null || echo none)"
fi

case_start 'action: an empty input-dir or output-dir fails closed'
dir="$(action_workspace)"
run_action "$dir" INPUT_DIR=''
first="$STEP_STATUS"
run_action "$dir" OUTPUT_DIR=''
if [ "$first" -ne 0 ] && [ "$STEP_STATUS" -ne 0 ] && [ ! -f "$dir/script" ]; then
    pass_case
else
    fail_case "statuses $first/$STEP_STATUS; script $(cat "$dir/script" 2>/dev/null || echo none)"
fi

case_start 'action: stills mode runs compose-web-media.sh with only the inputs that were set'
dir="$(action_workspace)"
run_action "$dir" MAX_AVIF_BYTES=1234 OUTPUT_TEMPLATE='{slug}/{dir}/{name}@2x' WEBP_ENCODER=magick
if [ "$STEP_STATUS" -eq 0 ]; then
    assert_equals compose-web-media.sh "$(cat "$dir/script")" 'script' \
        && assert_equals "--input-dir raw --output-dir out --device iphone --orientation auto --background transparent --output-template {slug}/{dir}/{name}@2x --webp-encoder magick --max-avif-bytes 1234 --manifest $(step_output "$dir" manifest)" "$(argv_of "$dir")" 'argv' \
        && assert_contains "$(step_output "$dir" manifest)" "$dir/runner-temp/compose-media." 'manifest output' \
        && assert_equals 2 "$(step_output "$dir" count)" 'count output' \
        && pass_case
else
    fail_case "step failed: $(cat "$dir/log")"
fi

case_start 'action: clips mode runs compose-web-clips.sh with the clip inputs'
dir="$(action_workspace)"
run_action "$dir" MODE=clips WEBM_CODEC=vp9 MAX_SECONDS=6 FPS=30 MAX_WEBM_BYTES=9 MAX_MP4_BYTES=8 MAX_POSTER_BYTES=7 MAX_AVIF_BYTES=1
if [ "$STEP_STATUS" -eq 0 ]; then
    assert_equals compose-web-clips.sh "$(cat "$dir/script")" 'script' \
        && assert_equals "--input-dir raw --output-dir out --webm-codec vp9 --max-seconds 6 --fps 30 --max-webm-bytes 9 --max-mp4-bytes 8 --max-poster-bytes 7 --manifest $(step_output "$dir" manifest)" "$(argv_of "$dir")" 'argv' \
        && pass_case
else
    fail_case "step failed: $(cat "$dir/log")"
fi

case_start 'action: frame mode runs frame-device.sh with the frame inputs'
dir="$(action_workspace)"
run_action "$dir" MODE=frame BACKGROUND='#F8F8F8-#F1F1F1' FIT=0.78 FRAMES_DIR=/frames FRAME_FILE=/f.png FRAME_CUTOUT=1,2,3,4
if [ "$STEP_STATUS" -eq 0 ]; then
    assert_equals frame-device.sh "$(cat "$dir/script")" 'script' \
        && assert_equals "--input-dir raw --output-dir out --device iphone --orientation auto --background #F8F8F8-#F1F1F1 --canvas capture --fit 0.78 --frames-dir /frames --frame /f.png --cutout 1,2,3,4 --manifest $(step_output "$dir" manifest)" "$(argv_of "$dir")" 'argv' \
        && pass_case
else
    fail_case "step failed: $(cat "$dir/log")"
fi

case_start 'action: a script that exits 0 without a manifest fails closed'
dir="$(action_workspace)"
printf 'exit 0\n' > "$dir/scripts/compose-web-media.sh"
run_action "$dir"
if [ "$STEP_STATUS" -ne 0 ]; then
    assert_contains "$(cat "$dir/log")" 'wrote no manifest' 'error' && pass_case
else
    fail_case 'step succeeded with no manifest'
fi

case_start 'action: a script failure fails the step'
dir="$(action_workspace)"
printf 'exit 3\n' > "$dir/scripts/compose-web-clips.sh"
run_action "$dir" MODE=clips
if [ "$STEP_STATUS" -ne 0 ] && [ "$(step_output "$dir" count)" = '' ]; then
    pass_case
else
    fail_case "status $STEP_STATUS, count '$(step_output "$dir" count)'"
fi

# --- store-screenshots.yml compose-command ---------------------------------

STORE_WORKFLOW="$REPO_ROOT/.github/workflows/store-screenshots.yml"

case_start 'store-screenshots: compose-command runs with SCREENSHOTS_DIR and its failure fails the step'
dir="$(new_workflow_workspace "$STORE_WORKFLOW" upload 'Run compose-command')"
# shellcheck disable=SC2016 # expanded by the step's eval.
run_step "$dir" COMPOSE_COMMAND='printf "%s\n" "$SCREENSHOTS_DIR" > composed.txt' SCREENSHOTS_DIR=fastlane/screenshots/raw
first="$STEP_STATUS"
composed="$(cat "$dir/work/composed.txt" 2>/dev/null || true)"
run_step "$dir" COMPOSE_COMMAND='exit 4' SCREENSHOTS_DIR=x
if [ "$first" -eq 0 ] && [ "$STEP_STATUS" -ne 0 ]; then
    assert_equals fastlane/screenshots/raw "$composed" 'SCREENSHOTS_DIR' && pass_case
else
    fail_case "statuses $first/$STEP_STATUS: $(cat "$dir/log")"
fi

case_start 'store-screenshots: compose-command sits between the merged download and the slot check, and is opt-in'
order="$(WORKFLOW_YML="$STORE_WORKFLOW" python3 - <<'PYTHON'
import os

import yaml

workflow = yaml.safe_load(open(os.environ['WORKFLOW_YML'], encoding='utf-8'))
steps = workflow['jobs']['upload']['steps']
names = [step.get('name') for step in steps]
wanted = ['Download raw screenshots', 'Run compose-command',
          'Validate iOS screenshot resolutions against apple-screenshot-slots', 'Run upload-command']
missing = [name for name in wanted if name not in names]
if missing:
    print('missing steps:', missing)
else:
    compose = steps[names.index('Run compose-command')]
    inputs = (workflow.get('on') or workflow[True])['workflow_call']['inputs']
    print(
        [names.index(name) for name in wanted] == sorted(names.index(name) for name in wanted),
        compose.get('if'),
        inputs.get('compose-command', {}).get('default'),
    )
PYTHON
)"
assert_equals "True inputs.compose-command != '' " "$order" 'step order, gate and default' && pass_case

# --- stubbed script cases ---------------------------------------------------

STILLS_ARGS='--input-dir raw --output-dir out'

case_start 'stills: a missing magick fails closed with an install hint'
dir="$(stub_media_workspace)"
rm "$dir/stub-bin/magick"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" "ImageMagick 7 ('magick') is required" 'error' \
    && assert_contains "$(cat "$dir/log")" 'brew install imagemagick' 'hint' && pass_case

case_start 'stills: a missing avifenc fails closed with an install hint'
dir="$(stub_media_workspace)"
rm "$dir/stub-bin/avifenc"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" "'avifenc' is required" 'error' \
    && assert_contains "$(cat "$dir/log")" 'libavif' 'hint' && pass_case

case_start 'stills: a missing cwebp fails closed and names the magick alternative'
dir="$(stub_media_workspace)"
rm "$dir/stub-bin/cwebp"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" "'cwebp' is required" 'error' \
    && assert_contains "$(cat "$dir/log")" '--webp-encoder magick' 'alternative' && pass_case

case_start 'stills: --webp-encoder magick needs no cwebp'
dir="$(stub_media_workspace)"
rm "$dir/stub-bin/cwebp"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS --webp-encoder magick
assert_succeeded "$dir" && assert_contains "$(cat "$dir/stub.log")" 'webp:method=6' 'magick encoded the webp' && pass_case

case_start 'stills: no frameit cache fails closed with the download hint'
dir="$(stub_media_workspace)"
rm -rf "$dir/home/.fastlane"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" 'fastlane frameit download_frames' 'hint' && pass_case

case_start 'stills: --frames-dir overrides the frameit cache location'
dir="$(stub_media_workspace)"
mv "$dir/home/.fastlane/frameit/latest" "$dir/frames"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS --frames-dir "$dir/frames"
assert_succeeded "$dir" && pass_case

case_start 'stills: an unknown argument fails closed'
dir="$(stub_media_workspace)"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS --raw-dir raw
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" "unknown argument '--raw-dir'" 'error' && pass_case

case_start 'stills: a non-integer byte budget fails closed'
dir="$(stub_media_workspace)"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS --max-avif-bytes 50k
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" '--max-avif-bytes' 'error names the flag' && pass_case

case_start 'stills: an unknown template token fails closed'
dir="$(stub_media_workspace)"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS --output-template '{locale}/{name}'
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" '{locale}' 'error names the token' && pass_case

case_start 'stills: a template escaping the output directory fails closed'
dir="$(stub_media_workspace)"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS --output-template '../{name}'
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" '..' 'error' && pass_case

case_start 'stills: an invalid background fails closed'
dir="$(stub_media_workspace)"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS --background red
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" "background 'red'" 'error' && pass_case

case_start 'stills: under budget, outputs publish at the rendered template path with a manifest'
dir="$(stub_media_workspace)"
RUN_ENV='STUB_AVIF_BYTES=300 STUB_WEBP_BYTES=400'
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS --output-template '{slug}/{grandparent}/{parent}/{name}@2x' \
    --max-avif-bytes 300 --max-webp-bytes 400 --manifest "$dir/manifest.tsv"
if assert_succeeded "$dir"; then
    assert_equals 300 "$(wc -c < "$dir/work/out/home-hero/en/light/home-hero-1@2x.avif" | tr -d ' ')" 'avif published' \
        && assert_equals 400 "$(wc -c < "$dir/work/out/home-hero/en/light/home-hero-1@2x.webp" | tr -d ' ')" 'webp published' \
        && assert_equals "$(printf 'home-hero/en/light/home-hero-1@2x.avif\t300\t300\nhome-hero/en/light/home-hero-1@2x.webp\t400\t400')" "$(cat "$dir/manifest.tsv")" 'manifest' \
        && pass_case
fi

case_start 'stills: the default template mirrors the input tree with an @2x suffix'
dir="$(stub_media_workspace)"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS
assert_succeeded "$dir" && assert_file "$dir/work/out/en/light/home-hero-1@2x.avif" \
    && assert_file "$dir/work/out/en/light/home-hero-1@2x.webp" && pass_case

case_start 'stills: one output over budget fails closed and publishes nothing'
dir="$(stub_media_workspace)"
printf '1320x2868\n' > "$dir/work/raw/en/light/second-1.png"
RUN_ENV='STUB_AVIF_BYTES=301 STUB_WEBP_BYTES=10'
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS --max-avif-bytes 300
if assert_failed "$dir"; then
    assert_contains "$(cat "$dir/log")" 'home-hero-1@2x.avif is 301 bytes, over the 300 byte budget' 'names the file and budget' \
        && assert_contains "$(cat "$dir/log")" 'second-1@2x.avif is 301 bytes' 'reports every overrun' \
        && assert_equals '' "$(find "$dir/work/out" -type f 2>/dev/null)" 'nothing published' \
        && pass_case
fi

case_start 'stills: a requested scene with no capture fails closed'
dir="$(stub_media_workspace)"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS --scenes home-hero-1,missing-scene
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" "missing-scene" 'error names the scene' \
    && assert_equals '' "$(find "$dir/work/out" -type f 2>/dev/null)" 'nothing published' && pass_case

case_start 'stills: an empty input tree fails closed'
dir="$(stub_media_workspace)"
rm -rf "$dir/work/raw"
mkdir -p "$dir/work/raw"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" 'composed nothing' 'error' && pass_case

case_start 'stills: --dry-run writes nothing'
dir="$(stub_media_workspace)"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS --dry-run
assert_succeeded "$dir" && assert_contains "$(cat "$dir/log")" 'would write' 'plan printed' \
    && assert_equals '' "$(find "$dir/work/out" -type f 2>/dev/null)" 'nothing written' && pass_case

case_start 'stills: a template that renders two inputs to one path fails closed, even under --dry-run'
dir="$(stub_media_workspace)"
mkdir -p "$dir/work/raw/fr/light"
printf '1320x2868\n' > "$dir/work/raw/fr/light/home-hero-1.png"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS --output-template '{name}' --dry-run
dry_status=$STEP_STATUS
dry_log="$(cat "$dir/log")"
# shellcheck disable=SC2086
run_script "$dir" compose-web-media.sh $STILLS_ARGS --output-template '{name}'
if assert_failed "$dir" \
    && assert_equals 1 "$([ "$dry_status" -ne 0 ] && echo 1 || echo 0)" "dry-run status ($dry_log)" \
    && assert_contains "$dry_log" "renders 'home-hero-1' for more than one input" 'dry-run error' \
    && assert_contains "$(cat "$dir/log")" "renders 'home-hero-1' for more than one input" 'error' \
    && assert_equals '' "$(find "$dir/work/out" -type f 2>/dev/null)" 'nothing published'; then
    pass_case
fi

clip_workspace() {
    local dir
    dir="$(stub_media_workspace)"
    rm -f "$dir/work/raw/en/light/home-hero-1.png"
    printf 'mp4\n' > "$dir/work/raw/en/light/voice-entry-clip-1.mp4"
    printf '1320x2868\n' > "$dir/work/raw/en/light/voice-entry-clip-1.png"
    printf '%s\n' "$dir"
}

case_start 'clips: a missing ffmpeg fails closed with an install hint'
dir="$(clip_workspace)"
rm "$dir/stub-bin/ffmpeg"
# shellcheck disable=SC2086
run_script "$dir" compose-web-clips.sh $STILLS_ARGS
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" "'ffmpeg' is required" 'error' \
    && assert_contains "$(cat "$dir/log")" 'brew install ffmpeg' 'hint' && pass_case

case_start 'clips: an ffmpeg without libx264 fails closed'
dir="$(clip_workspace)"
RUN_ENV='STUB_FFMPEG_ENCODERS=_V....._libvpx-vp9'
# shellcheck disable=SC2086
run_script "$dir" compose-web-clips.sh $STILLS_ARGS
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" 'libx264' 'error names the encoder' && pass_case

case_start 'clips: auto picks AV1 (libsvtav1) when the ffmpeg build has it'
dir="$(clip_workspace)"
# shellcheck disable=SC2086
run_script "$dir" compose-web-clips.sh $STILLS_ARGS
assert_succeeded "$dir" && assert_contains "$(cat "$dir/stub.log")" '-c:v libsvtav1' 'av1 encode' \
    && assert_not_contains "$(cat "$dir/stub.log")" 'libvpx-vp9' 'no vp9 encode' \
    && assert_contains "$(cat "$dir/stub.log")" '+faststart' 'mp4 is faststart' \
    && assert_file "$dir/work/out/en/light/voice-entry-clip-1.webm" && assert_file "$dir/work/out/en/light/voice-entry-clip-1.mp4" \
    && assert_file "$dir/work/out/en/light/voice-entry-clip-1-poster.webp" && pass_case

case_start 'clips: auto falls back to VP9 and says so when libsvtav1 is missing'
dir="$(clip_workspace)"
RUN_ENV='STUB_FFMPEG_ENCODERS=_V....._libx264\n_V....._libvpx-vp9'
# shellcheck disable=SC2086
run_script "$dir" compose-web-clips.sh $STILLS_ARGS
assert_succeeded "$dir" && assert_contains "$(cat "$dir/stub.log")" '-c:v libvpx-vp9' 'vp9 encode' \
    && assert_contains "$(cat "$dir/log")" 'libsvtav1' 'fallback is announced' && pass_case

case_start 'clips: --webm-codec av1 fails closed when libsvtav1 is missing'
dir="$(clip_workspace)"
RUN_ENV='STUB_FFMPEG_ENCODERS=_V....._libx264\n_V....._libvpx-vp9'
# shellcheck disable=SC2086
run_script "$dir" compose-web-clips.sh $STILLS_ARGS --webm-codec av1
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" 'libsvtav1' 'error names the encoder' && pass_case

case_start 'clips: a clip with no poster PNG fails closed'
dir="$(clip_workspace)"
rm "$dir/work/raw/en/light/voice-entry-clip-1.png"
# shellcheck disable=SC2086
run_script "$dir" compose-web-clips.sh $STILLS_ARGS
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" 'missing poster capture' 'error' && pass_case

case_start 'clips: the slug strips -clip-<n> and the template places the set'
dir="$(clip_workspace)"
# shellcheck disable=SC2086
run_script "$dir" compose-web-clips.sh $STILLS_ARGS --output-template '{slug}/{dir}/{name}'
assert_succeeded "$dir" && assert_file "$dir/work/out/voice-entry/en/light/voice-entry-clip-1.webm" && pass_case

case_start 'clips: an over-budget webm fails closed and publishes nothing'
dir="$(clip_workspace)"
RUN_ENV='STUB_WEBM_BYTES=5000'
# shellcheck disable=SC2086
run_script "$dir" compose-web-clips.sh $STILLS_ARGS --max-webm-bytes 4999
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" 'voice-entry-clip-1.webm is 5000 bytes, over the 4999 byte budget' 'error' \
    && assert_equals '' "$(find "$dir/work/out" -type f 2>/dev/null)" 'nothing published' && pass_case

case_start 'clips: never writes a GIF'
dir="$(clip_workspace)"
# shellcheck disable=SC2086
run_script "$dir" compose-web-clips.sh $STILLS_ARGS
assert_succeeded "$dir" && assert_equals '' "$(find "$dir/work/out" -name '*.gif')" 'no gif' \
    && assert_not_contains "$(cat "$dir/stub.log")" '.gif' 'no gif encode' && pass_case

case_start 'clips: a template that renders two clips to one path fails closed'
dir="$(clip_workspace)"
mkdir -p "$dir/work/raw/fr/light"
printf 'mp4\n' > "$dir/work/raw/fr/light/voice-entry-clip-1.mp4"
printf '1320x2868\n' > "$dir/work/raw/fr/light/voice-entry-clip-1.png"
# shellcheck disable=SC2086
run_script "$dir" compose-web-clips.sh $STILLS_ARGS --output-template '{slug}/{name}'
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" "renders 'voice-entry/voice-entry-clip-1' for more than one input" 'error' \
    && assert_equals '' "$(find "$dir/work/out" -type f 2>/dev/null)" 'nothing published' && pass_case

case_start 'frame: a template that renders two captures to one path fails closed'
dir="$(stub_media_workspace)"
mkdir -p "$dir/work/raw/fr/light"
printf '1320x2868\n' > "$dir/work/raw/fr/light/home-hero-1.png"
# shellcheck disable=SC2086
run_script "$dir" frame-device.sh $STILLS_ARGS --output-template '{name}'
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" "renders 'home-hero-1.png' for more than one input" 'error' \
    && assert_equals '' "$(find "$dir/work/out" -type f 2>/dev/null)" 'nothing published' && pass_case

case_start 'frame: an unknown device fails closed'
dir="$(stub_media_workspace)"
# shellcheck disable=SC2086
run_script "$dir" frame-device.sh $STILLS_ARGS --device watch
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" "unknown device 'watch'" 'error' && pass_case

case_start 'frame: a custom frame needs an explicit cutout'
dir="$(stub_media_workspace)"
# shellcheck disable=SC2086
run_script "$dir" frame-device.sh $STILLS_ARGS --frame "$dir/home/.fastlane/frameit/latest/$IPHONE_FRAME_NAME"
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" '--cutout' 'error' && pass_case

case_start 'frame: a cutout outside the frame fails closed'
dir="$(stub_media_workspace)"
# shellcheck disable=SC2086
run_script "$dir" frame-device.sh $STILLS_ARGS --frame "$dir/home/.fastlane/frameit/latest/$IPHONE_FRAME_NAME" --cutout 75,66,1400,2868
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" 'outside' 'error' && pass_case

case_start 'frame: a missing frame asset fails closed with the download hint'
dir="$(stub_media_workspace)"
rm "$dir/home/.fastlane/frameit/latest/$IPHONE_FRAME_NAME"
# shellcheck disable=SC2086
run_script "$dir" frame-device.sh $STILLS_ARGS
assert_failed "$dir" && assert_contains "$(cat "$dir/log")" "$IPHONE_FRAME_NAME" 'error names the frame' \
    && assert_contains "$(cat "$dir/log")" 'fastlane frameit download_frames' 'hint' && pass_case

case_start 'frame: a sourced frame-device.sh derives the landscape iPad cutout suuudokuuu measured'
dir="$(stub_media_workspace)"
(
    cd "$dir/work" || exit 1
    # shellcheck disable=SC2016 # expanded by the inner shell.
    env -i PATH="$dir/stub-bin:$dir/sandbox" HOME="$dir/home" bash -c '
        set -euo pipefail
        . "$1/frame-device.sh"
        WORK_ROOT="$(mktemp -d)"
        resolve_frameit_frames_dir
        frame_device_select ipad landscape
        printf "%s %s %s %s\n" "$DEVICE_CUTOUT_X" "$DEVICE_CUTOUT_Y" "$DEVICE_CUTOUT_W" "$DEVICE_CUTOUT_H"' _ "$MEDIA"
) > "$dir/log" 2>&1 || true
assert_equals '96 96 2732 2048' "$(tail -n 1 "$dir/log")" 'landscape cutout' && pass_case

case_start 'frame: a sourced frame-device.sh rotates each custom frame into its own landscape file'
dir="$(stub_media_workspace)"
(
    cd "$dir/work" || exit 1
    # shellcheck disable=SC2016 # expanded by the inner shell.
    env -i PATH="$dir/stub-bin:$dir/sandbox" HOME="$dir/home" bash -c '
        set -euo pipefail
        . "$1/frame-device.sh"
        WORK_ROOT="$(mktemp -d)"
        resolve_frameit_frames_dir
        mkdir -p a b
        cp "$FRAMES_DIR/$IPAD_FRAME_NAME" a/frame.png
        cp "$FRAMES_DIR/$IPAD_FRAME_NAME" b/frame.png
        FRAME_DEVICE_CUTOUT="$IPAD_FRAME_CUTOUT"
        FRAME_DEVICE_FRAME=a/frame.png frame_device_select ipad landscape
        first="$DEVICE_FRAME"
        FRAME_DEVICE_FRAME=b/frame.png frame_device_select ipad landscape
        [ -f "$first" ] && [ -f "$DEVICE_FRAME" ] || echo missing
        if [ "$first" = "$DEVICE_FRAME" ]; then echo shared; else echo distinct; fi' _ "$MEDIA"
) > "$dir/log" 2>&1 || true
assert_equals 'distinct' "$(tail -n 1 "$dir/log")" 'landscape frame per source frame' && pass_case

# --- real-tool cases ---------------------------------------------------------

# synthesize_frame — budgie's own fixture: an opaque #1A1A1A slab with a fully
# transparent cutout rectangle, at the real frame's pixel geometry.
synthesize_frame() {
    local out="$1" frame_w="$2" frame_h="$3" cut_x="$4" cut_y="$5" cut_w="$6" cut_h="$7" mask
    mask="$(dirname "$out")/frame-mask-$$.png"
    magick -size "${frame_w}x${frame_h}" xc:white -fill black \
        -draw "rectangle ${cut_x},${cut_y} $((cut_x + cut_w - 1)),$((cut_y + cut_h - 1))" -alpha off "$mask"
    magick -size "${frame_w}x${frame_h}" xc:'#1A1A1A' "$mask" -alpha off -compose CopyOpacity -composite -define png:color-type=6 "$out"
    rm -f "$mask"
}

real_workspace() {
    local dir frames
    dir="$(new_empty_workspace)"
    frames="$dir/home/.fastlane/frameit/latest"
    mkdir -p "$frames" "$dir/work/raw/en/light"
    synthesize_frame "$frames/$IPHONE_FRAME_NAME" 1470 3000 75 66 1320 2868
    synthesize_frame "$frames/$IPAD_FRAME_NAME" 2245 2930 96 102 2048 2732
    printf '%s\n' "$dir"
}

pixels_differ() {
    magick compare -metric AE "$1" "$2" null: 2>&1 | awk '{ print $1 }' || true
}

run_real() {
    local dir="$1" script="$2"
    shift 2
    STEP_STATUS=0
    (cd "$dir/work" && HOME="$dir/home" bash "$script" "$@") > "$dir/log" 2>&1 || STEP_STATUS=$?
}

webp_encoder_like_budgie() {
    if command -v cwebp >/dev/null 2>&1; then printf cwebp; else printf magick; fi
}

if tool="$(missing_tool magick)"; then
    skip_case 'parity: frame_capture matches budgie and suuudokuuu for every device' "'$tool' is not installed"
    skip_case 'frame: the store canvas keeps the capture size on an opaque plate' "'$tool' is not installed"
    skip_case 'frame: a transparent capture canvas keeps its alpha' "'$tool' is not installed"
else
    case_start 'parity: frame_capture matches budgie and suuudokuuu for every device'
    dir="$(real_workspace)"
    magick -size 1320x2868 gradient:'#3366FF-#FFFFFF' -alpha off "$dir/work/iphone.png"
    magick -size 2048x2732 gradient:'#FF6633-#000000' -alpha off "$dir/work/ipad.png"
    magick -size 2732x2048 gradient:'#33AA66-#FFFFFF' -alpha off "$dir/work/ipad-landscape.png"
    STEP_STATUS=0
    (
        cd "$dir/work" || exit 1
        export HOME="$dir/home"
        bash -c '
            set -euo pipefail
            . "$1/frame-device.sh"
            WORK_ROOT="$PWD"
            resolve_frameit_frames_dir
            resolve_device_frames
            frame_capture iphone.png "$IPHONE_FRAME" "$IPHONE_CUTOUT_X" "$IPHONE_CUTOUT_Y" "$IPHONE_CUTOUT_W" "$IPHONE_CUTOUT_H" ref-iphone.png
            frame_capture ipad.png "$IPAD_FRAME" "$IPAD_CUTOUT_X" "$IPAD_CUTOUT_Y" "$IPAD_CUTOUT_W" "$IPAD_CUTOUT_H" ref-ipad.png
            magick "$IPAD_FRAME" -rotate 90 -define png:color-type=6 -depth 8 suu-ipad-landscape-frame.png
            frame_capture ipad-landscape.png suu-ipad-landscape-frame.png 96 96 2732 2048 ref-ipad-landscape.png
        ' _ "$REFERENCE"
        bash -c '
            set -euo pipefail
            . "$1/frame-device.sh"
            WORK_ROOT="$PWD"
            resolve_frameit_frames_dir
            frame_device_select iphone portrait
            frame_capture iphone.png "$DEVICE_FRAME" "$DEVICE_CUTOUT_X" "$DEVICE_CUTOUT_Y" "$DEVICE_CUTOUT_W" "$DEVICE_CUTOUT_H" new-iphone.png
            frame_device_select ipad portrait
            frame_capture ipad.png "$DEVICE_FRAME" "$DEVICE_CUTOUT_X" "$DEVICE_CUTOUT_Y" "$DEVICE_CUTOUT_W" "$DEVICE_CUTOUT_H" new-ipad.png
            frame_device_select ipad landscape
            frame_capture ipad-landscape.png "$DEVICE_FRAME" "$DEVICE_CUTOUT_X" "$DEVICE_CUTOUT_Y" "$DEVICE_CUTOUT_W" "$DEVICE_CUTOUT_H" new-ipad-landscape.png
        ' _ "$MEDIA"
    ) > "$dir/log" 2>&1 || STEP_STATUS=$?
    if [ "$STEP_STATUS" -ne 0 ]; then
        fail_case "framing failed: $(cat "$dir/log")"
    else
        assert_equals 0 "$(pixels_differ "$dir/work/ref-iphone.png" "$dir/work/new-iphone.png")" 'iPhone differing pixels' \
            && assert_equals 0 "$(pixels_differ "$dir/work/ref-ipad.png" "$dir/work/new-ipad.png")" 'iPad portrait differing pixels' \
            && assert_equals 0 "$(pixels_differ "$dir/work/ref-ipad-landscape.png" "$dir/work/new-ipad-landscape.png")" 'iPad landscape differing pixels' \
            && assert_equals "$(magick identify -format '%wx%h' "$dir/work/ref-ipad-landscape.png")" "$(magick identify -format '%wx%h' "$dir/work/new-ipad-landscape.png")" 'iPad landscape size' \
            && pass_case
    fi
    STEP_STATUS=0

    case_start 'frame: the store canvas keeps the capture size on an opaque plate'
    dir="$(real_workspace)"
    magick -size 1320x2868 gradient:'#3366FF-#FFFFFF' -alpha off "$dir/work/raw/en/light/01-home.png"
    run_real "$dir" "$MEDIA/frame-device.sh" --input-dir raw --output-dir out --background '#F8F8F8-#F1F1F1' --fit 0.78
    shot="$dir/work/out/en/light/01-home.png"
    if [ "$STEP_STATUS" -ne 0 ]; then
        fail_case "frame-device.sh failed: $(cat "$dir/log")"
    else
        assert_equals 1320x2868 "$(magick identify -format '%wx%h' "$shot")" 'exact capture pixel size deliver matches slots on' \
            && assert_equals Undefined "$(magick identify -format '%A' "$shot")" 'opaque' \
            && assert_equals F8F8F8 "$(magick "$shot" -format '%[hex:p{0,0}]' info:)" 'plate fills the corner' \
            && assert_equals 1 "$(magick "$shot" -format '%[fx:p{660,1600}.r < 0.9]' info:)" 'device covers the middle' \
            && pass_case
    fi

    case_start 'frame: a transparent capture canvas keeps its alpha'
    dir="$(real_workspace)"
    magick -size 1320x2868 gradient:'#3366FF-#FFFFFF' -alpha off "$dir/work/raw/en/light/01-home.png"
    run_real "$dir" "$MEDIA/frame-device.sh" --input-dir raw --output-dir out
    shot="$dir/work/out/en/light/01-home.png"
    if [ "$STEP_STATUS" -ne 0 ]; then
        fail_case "frame-device.sh failed: $(cat "$dir/log")"
    else
        assert_equals 1320x2868 "$(magick identify -format '%wx%h' "$shot")" 'size' \
            && assert_equals 0 "$(magick "$shot" -format '%[fx:p{0,0}.a]' info:)" 'corner is transparent' \
            && pass_case
    fi
fi

if tool="$(missing_tool magick avifenc "$(webp_encoder_like_budgie)")"; then
    skip_case 'stills: budgie fixture composes to the 900x1955 contract within budget' "'$tool' is not installed"
    skip_case 'parity: compose-web-media.sh matches budgie byte for byte' "'$tool' is not installed"
else
    case_start 'stills: budgie fixture composes to the 900x1955 contract within budget'
    dir="$(real_workspace)"
    magick -size 1320x2868 gradient:'#3366FF-#FFFFFF' -alpha off "$dir/work/raw/en/light/home-hero-1.png"
    # Budgie's own budgets for this flat-gradient fixture: ~25% over its
    # measured output at the tuned settings (cwebp; the magick WebP coder
    # lands within the same 9000).
    run_real "$dir" "$MEDIA/compose-web-media.sh" --input-dir raw --output-dir out \
        --output-template '{slug}/{dir}/{name}@2x' --webp-encoder "$(webp_encoder_like_budgie)" \
        --max-avif-bytes 2600 --max-webp-bytes 9000
    avif="$dir/work/out/home-hero/en/light/home-hero-1@2x.avif"
    webp="$dir/work/out/home-hero/en/light/home-hero-1@2x.webp"
    if [ "$STEP_STATUS" -ne 0 ]; then
        fail_case "compose-web-media.sh failed: $(cat "$dir/log")"
    else
        assert_equals 900x1955 "$(magick identify -format '%wx%h' "$avif")" 'avif size' \
            && assert_equals 900x1955 "$(magick identify -format '%wx%h' "$webp")" 'webp size' \
            && pass_case
    fi

    case_start 'parity: compose-web-media.sh matches budgie byte for byte'
    dir="$(real_workspace)"
    mkdir -p "$dir/work/budgie-raw/ios/iphone-17-pro-max/en/light"
    magick -size 1320x2868 gradient:'#3366FF-#FFFFFF' -alpha off "$dir/work/budgie-raw/ios/iphone-17-pro-max/en/light/home-hero-1.png"
    magick -size 1320x2868 gradient:'#202020-#E0E0E0' -alpha off "$dir/work/budgie-raw/ios/iphone-17-pro-max/en/light/budget-2.png"
    run_real "$dir" "$REFERENCE/compose-web-media.sh" --raw-dir budgie-raw --output reference
    reference_status="$STEP_STATUS"
    run_real "$dir" "$MEDIA/compose-web-media.sh" --input-dir budgie-raw/ios/iphone-17-pro-max --output-dir extracted \
        --output-template '{slug}/{dir}/{name}@2x' --webp-encoder "$(webp_encoder_like_budgie)"
    if [ "$reference_status" -ne 0 ] || [ "$STEP_STATUS" -ne 0 ]; then
        fail_case "a compose failed ($reference_status/$STEP_STATUS): $(cat "$dir/log")"
    elif diff -r "$dir/work/reference" "$dir/work/extracted" > "$dir/diff" 2>&1; then
        assert_equals 4 "$(find "$dir/work/extracted" -type f | wc -l | tr -d ' ')" 'file count' && pass_case
    else
        fail_case "outputs differ from budgie's: $(cat "$dir/diff")"
    fi
fi

if tool="$(missing_tool magick ffmpeg ffprobe "$(webp_encoder_like_budgie)")"; then
    skip_case 'clips: budgie fixture encodes webm + faststart mp4 + poster at 24 fps' "'$tool' is not installed"
    skip_case 'parity: compose-web-clips.sh --webm-codec vp9 matches budgie frame for frame' "'$tool' is not installed"
else
    clip_fixture() {
        local raw="$1"
        mkdir -p "$raw"
        ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=size=1320x2868:duration=1:rate=10 \
            -pix_fmt yuv420p "$raw/voice-transaction-entry-clip-1.mp4"
        magick -size 1320x2868 xc:'#3366FF' "$raw/voice-transaction-entry-clip-1.png"
    }

    case_start 'clips: budgie fixture encodes webm + faststart mp4 + poster at 24 fps'
    dir="$(real_workspace)"
    clip_fixture "$dir/work/raw/en/light"
    run_real "$dir" "$MEDIA/compose-web-clips.sh" --input-dir raw --output-dir out \
        --output-template '{slug}/{dir}/{name}' --webp-encoder "$(webp_encoder_like_budgie)"
    dest="$dir/work/out/voice-transaction-entry/en/light"
    if [ "$STEP_STATUS" -ne 0 ]; then
        fail_case "compose-web-clips.sh failed: $(cat "$dir/log")"
    else
        expected_codec=vp9
        encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"
        case "$encoders" in *' libsvtav1 '*) expected_codec=av1 ;; esac
        moov="$(grep -boa moov "$dest/voice-transaction-entry-clip-1.mp4" | head -n 1 | cut -d: -f1)"
        mdat="$(grep -boa mdat "$dest/voice-transaction-entry-clip-1.mp4" | head -n 1 | cut -d: -f1)"
        assert_equals 24/1 "$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$dest/voice-transaction-entry-clip-1.webm")" 'webm fps' \
            && assert_equals 24/1 "$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$dest/voice-transaction-entry-clip-1.mp4")" 'mp4 fps' \
            && assert_equals "$expected_codec" "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$dest/voice-transaction-entry-clip-1.webm")" 'webm codec' \
            && assert_equals h264 "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$dest/voice-transaction-entry-clip-1.mp4")" 'mp4 codec' \
            && assert_equals 1 "$([ "$moov" -lt "$mdat" ] && echo 1 || echo 0)" "moov ($moov) precedes mdat ($mdat)" \
            && assert_equals 900x1955 "$(magick identify -format '%wx%h' "$dest/voice-transaction-entry-clip-1-poster.webp")" 'poster size' \
            && pass_case
    fi

    case_start 'parity: compose-web-clips.sh --webm-codec vp9 matches budgie frame for frame'
    dir="$(real_workspace)"
    clip_fixture "$dir/work/budgie-raw/ios/iphone-17-pro-max/en/light"
    run_real "$dir" "$REFERENCE/compose-web-clips.sh" --raw-dir budgie-raw --output reference
    reference_status="$STEP_STATUS"
    run_real "$dir" "$MEDIA/compose-web-clips.sh" --input-dir budgie-raw/ios/iphone-17-pro-max --output-dir extracted \
        --output-template '{slug}/{dir}/{name}' --webm-codec vp9 --webp-encoder "$(webp_encoder_like_budgie)"
    if [ "$reference_status" -ne 0 ] || [ "$STEP_STATUS" -ne 0 ]; then
        fail_case "a compose failed ($reference_status/$STEP_STATUS): $(cat "$dir/log")"
    else
        rel=voice-transaction-entry/en/light/voice-transaction-entry-clip-1
        frames_md5() { ffmpeg -v error -i "$1" -map 0:v -f md5 - 2>&1; }
        assert_equals "$(frames_md5 "$dir/work/reference/$rel.webm")" "$(frames_md5 "$dir/work/extracted/$rel.webm")" 'webm frames' \
            && assert_equals "$(frames_md5 "$dir/work/reference/$rel.mp4")" "$(frames_md5 "$dir/work/extracted/$rel.mp4")" 'mp4 frames' \
            && assert_equals 0 "$(pixels_differ "$dir/work/reference/$rel-poster.webp" "$dir/work/extracted/$rel-poster.webp")" 'poster pixels' \
            && pass_case
    fi
fi

if [ "$SKIPPED" -gt 0 ]; then
    printf '\n%s real-tool case(s) skipped locally; self-test.yml installs every tool so none skip in CI.\n' "$SKIPPED"
fi
finish_suite
