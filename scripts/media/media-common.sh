# shellcheck shell=bash
# Shared plumbing for frame-device.sh, compose-web-media.sh and
# compose-web-clips.sh: tool preflight, argument validation, input discovery,
# output-path templates, byte budgets, and all-or-nothing publishing.
# Bash 3.2 compatible (macOS /bin/bash): no mapfile, no associative arrays.

media_fail() {
    echo "error: $*" >&2
    exit 1
}

media_require_magick() {
    command -v magick >/dev/null 2>&1 \
        || media_fail "ImageMagick 7 ('magick') is required on PATH. Install it with 'brew install imagemagick' on macOS; on Linux, distro packages are often ImageMagick 6 (no 'magick'), so use the AppImage from https://github.com/ImageMagick/ImageMagick/releases."
}

media_require_avifenc() {
    command -v avifenc >/dev/null 2>&1 \
        || media_fail "'avifenc' is required on PATH to encode AVIF. Install libavif: 'brew install libavif' on macOS, 'apt-get install libavif-bin' on Debian/Ubuntu."
}

media_require_webp_encoder() {
    case "$1" in
        cwebp)
            command -v cwebp >/dev/null 2>&1 \
                || media_fail "'cwebp' is required on PATH to encode WebP. Install it with 'brew install webp' on macOS or 'apt-get install webp' on Debian/Ubuntu, or pass --webp-encoder magick to use ImageMagick's WebP coder instead."
            ;;
        magick) media_require_magick ;;
        *) media_fail "unknown --webp-encoder '$1'. Use cwebp or magick." ;;
    esac
}

media_require_ffmpeg() {
    command -v ffmpeg >/dev/null 2>&1 \
        || media_fail "'ffmpeg' is required on PATH. Install it with 'brew install ffmpeg' on macOS or 'apt-get install ffmpeg' on Debian/Ubuntu."
}

media_ffmpeg_has_encoder() {
    local encoders
    encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"
    grep -Eq "[[:space:]_]$1([[:space:]_]|\$)" <<EOF
$encoders
EOF
}

media_require_positive_int() {
    case "$2" in
        '' | *[!0-9]* | 0*) media_fail "$1 must be a positive integer, got '$2'." ;;
    esac
}

media_require_fraction() {
    if ! printf '%s\n' "$2" | grep -Eq '^(0?\.[0-9]*[1-9][0-9]*|1(\.0*)?)$'; then
        media_fail "$1 must be a number in (0, 1], got '$2'."
    fi
}

media_require_value() {
    if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        media_fail "$1 needs a value."
    fi
}

# media_list_inputs <dir> <extension> — sorted paths relative to <dir>.
media_list_inputs() {
    (cd "$1" && find . -type f -name "*.$2" | sed 's#^\./##' | LC_ALL=C sort)
}

# media_scene_selected <scene> — true when no --scenes filter is set or the
# filter names the scene.
media_scene_selected() {
    [ -z "$MEDIA_SCENES" ] && return 0
    case ",$MEDIA_SCENES," in
        *",$1,"*) return 0 ;;
    esac
    return 1
}

# media_check_scenes_found <list of matched scene names, newline separated>
media_check_scenes_found() {
    local matched="$1" scene missing=''
    [ -z "$MEDIA_SCENES" ] && return 0
    local old_ifs="$IFS"
    IFS=','
    for scene in $MEDIA_SCENES; do
        [ -n "$scene" ] || continue
        if ! printf '%s\n' "$matched" | grep -Fxq "$scene"; then
            missing="$missing $scene"
        fi
    done
    IFS="$old_ifs"
    [ -z "$missing" ] || media_fail "--scenes named scene(s) with no capture under $MEDIA_INPUT_DIR:$missing"
}

media_validate_template() {
    local rest="$1"
    case "$rest" in
        '') media_fail '--output-template must not be empty.' ;;
        /* | *..*) media_fail "--output-template '$1' must stay inside the output directory (no leading '/' and no '..')." ;;
        *'{name}'*) ;;
        *) media_fail "--output-template '$1' must contain {name}, or every capture would write the same file." ;;
    esac
    rest="$(printf '%s' "$rest" | sed -e 's/{dir}//g' -e 's/{name}//g' -e 's/{slug}//g' -e 's/{parent}//g' -e 's/{grandparent}//g')"
    case "$rest" in
        *'{'* | *'}'*)
            media_fail "--output-template '$1' has an unknown token ($(printf '%s' "$rest" | grep -o '{[^}]*}' | head -n 1)). Known tokens: {dir} {name} {slug} {parent} {grandparent}."
            ;;
    esac
}

# media_render_template <template> <relative input path> <slug>
media_render_template() {
    local template="$1" rel="$2" slug="$3" dir name parent grandparent rendered
    name="$(basename "$rel")"
    name="${name%.*}"
    dir="$(dirname "$rel")"
    [ "$dir" = . ] && dir=''
    parent=''
    grandparent=''
    if [ -n "$dir" ]; then
        parent="$(basename "$dir")"
        case "$dir" in
            */*) grandparent="$(basename "$(dirname "$dir")")" ;;
        esac
    fi
    rendered="$template"
    rendered="${rendered//\{dir\}/$dir}"
    rendered="${rendered//\{name\}/$name}"
    rendered="${rendered//\{slug\}/$slug}"
    rendered="${rendered//\{parent\}/$parent}"
    rendered="${rendered//\{grandparent\}/$grandparent}"
    printf '%s\n' "$rendered" | sed -e 's#//*#/#g' -e 's#^/##'
}

# media_claim_output <rendered path> — fails closed when --output-template
# renders the same path for two inputs, which would otherwise overwrite the
# first output and publish fewer files than the manifest lists.
media_claim_output() {
    if printf '%s' "$MEDIA_CLAIMED" | grep -Fxq -- "$1"; then
        media_fail "--output-template renders '$1' for more than one input; add {dir}, {parent} or {grandparent} to tell them apart."
    fi
    MEDIA_CLAIMED="$MEDIA_CLAIMED$1
"
}

media_bytes() {
    wc -c < "$1" | tr -d ' '
}

# media_budget <staged file> <budget> — records the file in the manifest and
# any overrun in MEDIA_OVERRUNS; the caller fails after every file is checked.
media_budget() {
    local file="$1" budget="$2" rel bytes
    rel="${file#"$MEDIA_STAGE"/}"
    bytes="$(media_bytes "$file")"
    printf '%s\t%s\t%s\n' "$rel" "$bytes" "$budget" >> "$MEDIA_WORK/manifest.tsv"
    if [ "$bytes" -gt "$budget" ]; then
        MEDIA_OVERRUNS="${MEDIA_OVERRUNS}  $rel is $bytes bytes, over the $budget byte budget
"
    fi
}

media_init_work() {
    MEDIA_WORK="$(mktemp -d "${TMPDIR:-/tmp}/mobile-ci-media.XXXXXX")"
    MEDIA_STAGE="$MEDIA_WORK/stage"
    mkdir -p "$MEDIA_STAGE"
    : > "$MEDIA_WORK/manifest.tsv"
    MEDIA_OVERRUNS=''
    MEDIA_CLAIMED=''
    # shellcheck disable=SC2034 # frame_capture's scratch directory.
    WORK_ROOT="$MEDIA_WORK"
    # shellcheck disable=SC2064 # expand now: the path is fixed for this run.
    trap "rm -rf '$MEDIA_WORK'" EXIT
}

# media_publish <count> <noun> — fails closed on an empty run or any budget
# overrun, otherwise copies the staged tree into the output directory.
media_publish() {
    local count="$1" noun="$2"
    if [ "$count" -eq 0 ]; then
        media_fail "composed nothing: no $noun matched under $MEDIA_INPUT_DIR"
    fi
    if [ "$MEDIA_DRY_RUN" -eq 1 ]; then
        echo "dry run: would compose $count $noun(s) into $MEDIA_OUTPUT_DIR"
        return 0
    fi
    if [ -n "$MEDIA_OVERRUNS" ]; then
        printf 'error: byte budget exceeded; nothing was published to %s:\n%s' "$MEDIA_OUTPUT_DIR" "$MEDIA_OVERRUNS" >&2
        exit 1
    fi
    mkdir -p "$MEDIA_OUTPUT_DIR"
    cp -R "$MEDIA_STAGE/." "$MEDIA_OUTPUT_DIR/"
    if [ -n "$MEDIA_MANIFEST" ]; then
        mkdir -p "$(dirname "$MEDIA_MANIFEST")"
        cp "$MEDIA_WORK/manifest.tsv" "$MEDIA_MANIFEST"
    fi
    echo "composed $count $noun(s) into $MEDIA_OUTPUT_DIR"
}

media_require_dirs() {
    [ -n "$MEDIA_INPUT_DIR" ] || media_fail '--input-dir is required.'
    [ -n "$MEDIA_OUTPUT_DIR" ] || media_fail '--output-dir is required.'
    [ -d "$MEDIA_INPUT_DIR" ] || media_fail "composed nothing: --input-dir '$MEDIA_INPUT_DIR' is not a directory."
}
