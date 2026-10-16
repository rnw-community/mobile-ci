# compose-media

Frames raw device captures in fastlane frameit's real device frames and encodes
them for a store listing or a landing page. It wraps three scripts under
[`scripts/media/`](../../scripts/media), which also run locally:

| Mode     | Script                 | Input                                    | Output per input                                      |
| -------- | ---------------------- | ---------------------------------------- | ------------------------------------------------------ |
| `frame`  | `frame-device.sh`      | `*.png` captures                         | framed PNG (capture-sized or frame-sized canvas)       |
| `stills` | `compose-web-media.sh` | `*.png` captures                         | framed AVIF + WebP at a fixed 2x size (default 900 wide) |
| `clips`  | `compose-web-clips.sh` | `*.mp4` recordings + sibling `<scene>.png` | WebM (AV1, or VP9 when ffmpeg lacks libsvtav1) + H.264 MP4 with `+faststart` + WebP poster. Never a GIF. |

**Captions and store copy stay with the app.** The frame mode puts a device in
its bezel on a transparent or plate background; headline text, layout and
palettes belong in the consumer's own composer, which can source
`frame-device.sh` for the framing primitives and lay the device out itself.

**Fail closed.** A missing tool, a missing frame asset, a bad argument, a
`scenes` entry with no capture, a clip with no poster, or any file over its byte
budget fails the step. Every output is staged first; nothing is published to
`output-dir` unless every input composed within budget.

Lifted from budgie-at/budgie@`9c3e1f0939e797ed7920ffcd6e23b3a323442d79`
(`packages/app/fastlane/screenshots/design/{frame-device,compose-web-media,compose-web-clips}.sh`).
`frame_capture` is the algorithm both budgie and vitalyiegorov/suuudokuuu ship,
and the encoder settings are budgie's measured ones. The tests check pixel
parity against budgie's scripts, kept under
`fixtures/compose-media/budgie-reference`.

## Tool dependencies

Nothing is installed for you. Each script checks for the tools it needs first
and fails with an install hint.

| Tool                  | Needed by                         | Install                                                                                     |
| --------------------- | --------------------------------- | -------------------------------------------------------------------------------------------- |
| ImageMagick 7 `magick` | every mode                        | `brew install imagemagick`; on Linux use the [AppImage](https://github.com/ImageMagick/ImageMagick/releases) (distro packages are often ImageMagick 6, which has no `magick`) |
| frameit frame assets  | `frame`, `stills`                 | `fastlane frameit download_frames` (cached at `~/.fastlane/frameit/latest`), or `frames-dir` / `frame-file` |
| `avifenc` (libavif)   | `stills`                          | `brew install libavif` / `apt-get install libavif-bin`                                       |
| `cwebp`               | `stills`, `clips` (unless `webp-encoder: magick`) | `brew install webp` / `apt-get install webp`                                  |
| `ffmpeg` with `libx264` and `libsvtav1` or `libvpx-vp9` | `clips` | `brew install ffmpeg` / `apt-get install ffmpeg`                                      |

## Devices and frames

| `device` | frameit asset                                              | Cutout (portrait)        | Slug                  |
| -------- | ---------------------------------------------------------- | ------------------------ | --------------------- |
| `iphone` | `Apple iPhone 16 Pro Max Black Titanium.png` (6.9" panel)   | `75,66,1320,2868`        | `iphone-17-pro-max`   |
| `ipad`   | `Apple iPad Pro (12.9-inch) (4th generation) Space Gray.png` (closest to the 13" M4) | `96,102,2048,2732` | `ipad-pro-13-inch-m4` |

With `orientation: auto`, a capture wider than it is tall gets the portrait
frame rotated 90° clockwise, and the cutout is rotated with it rather than
re-measured: `96,96,2732,2048` for the iPad, which is suuudokuuu's measured
landscape cutout. If you pass your own `frame-file`, it needs its measured
`frame-cutout`. A cutout outside the frame fails the step.

## Output paths

`output-template` places each output under `output-dir`. The extension is
appended (`.png`; `.avif`/`.webp`; `.webm`/`.mp4`/`-poster.webp`). Tokens are
resolved against the input's path relative to `input-dir`:

| Token           | Value for `input-dir/en/light/home-hero-1.png` |
| --------------- | ----------------------------------------------- |
| `{dir}`         | `en/light`                                      |
| `{name}`        | `home-hero-1`                                   |
| `{slug}`        | `home-hero` (trailing `-<n>` stripped; in `clips`, then also `-clip`) |
| `{parent}`      | `light`                                         |
| `{grandparent}` | `en`                                            |

Budgie's landing layout is `{slug}/{dir}/{name}@2x` (stills) and
`{slug}/{dir}/{name}` (clips), with `input-dir` set to
`<raw>/ios/iphone-17-pro-max`.

## Inputs

| Name               | Required | Default       | Description |
| ------------------ | -------- | ------------- | ----------- |
| `mode`             | yes      | —             | `frame`, `stills`, or `clips`. |
| `input-dir`        | yes      | —             | Directory scanned recursively for `*.png` captures (`frame`, `stills`) or `*.mp4` recordings with a sibling `<scene>.png` poster (`clips`). |
| `output-dir`       | yes      | —             | Directory the composed files are published into, only after every input composed within budget. |
| `output-template`  | no       | `''`          | See [Output paths](#output-paths). Empty uses `{dir}/{name}` (frame, clips) or `{dir}/{name}@2x` (stills). |
| `scenes`           | no       | `''`          | Comma-separated input basenames to compose. Each one must exist. Empty composes every input. |
| `device`           | no       | `iphone`      | `frame`/`stills`: `iphone` or `ipad`. |
| `orientation`      | no       | `auto`        | `frame`/`stills`: `auto`, `portrait`, or `landscape`. |
| `background`       | no       | `transparent` | `frame`/`stills`: `transparent`, `#RRGGBB`, or a top-to-bottom `#RRGGBB-#RRGGBB` plate. A plate makes the output opaque. |
| `canvas`           | no       | `capture`     | `frame`: `capture` (the capture's own pixel size, which App Store Connect slots match on) or `frame` (the frame's native size). |
| `fit`              | no       | `''`          | `frame`: fraction (0,1] of the capture canvas the device is contained in. Empty uses `1`. |
| `width`            | no       | `''`          | `stills`: output width. Empty uses `900`. |
| `height`           | no       | `''`          | `stills`: output height. Empty derives it from the width and the capture's aspect ratio (`1955` for a 1320x2868 capture). |
| `frames-dir`       | no       | `''`          | `frame`/`stills`: frameit frames directory. Empty uses the fastlane cache. |
| `frame-file`       | no       | `''`          | `frame`/`stills`: your own frame PNG. Needs `frame-cutout`. |
| `frame-cutout`     | no       | `''`          | `frame`/`stills`: `X,Y,W,H` screen cutout of `frame-file`. |
| `webp-encoder`     | no       | `''`          | `stills`/`clips`: `cwebp` or `magick`. Empty uses `cwebp`. |
| `webm-codec`       | no       | `''`          | `clips`: `auto`, `av1`, or `vp9`. Empty uses `auto`, which picks AV1 and falls back to VP9 with a note when ffmpeg has no `libsvtav1`. `av1` and `vp9` fail if their encoder is missing. |
| `max-seconds`      | no       | `''`          | `clips`: length cap. Empty uses `8`. |
| `fps`              | no       | `''`          | `clips`: output frame rate. Empty uses `24`. |
| `max-avif-bytes`   | no       | `''`          | `stills`: per-file budget. Empty uses `60000`. |
| `max-webp-bytes`   | no       | `''`          | `stills`: per-file budget. Empty uses `90000`. |
| `max-webm-bytes`   | no       | `''`          | `clips`: per-file budget. Empty uses `400000`. |
| `max-mp4-bytes`    | no       | `''`          | `clips`: per-file budget. Empty uses `400000`. |
| `max-poster-bytes` | no       | `''`          | `clips`: per-file budget. Empty uses `90000`. |

The default budgets leave about 2x headroom over the measured averages for real
900-wide content. These are budgie's AVIF (27 KB) and WebP (40.5 KB) stills
averages, and the 6.5 s 1320x2868 slide-transition clip where AV1 at
`-crf 42 -preset 6` came out at 196 KB (VP9 at budgie's settings: 247 KB) and
H.264 at 170 KB. Tighten them to your own content.

## Outputs

| Name       | Description |
| ---------- | ----------- |
| `manifest` | Path to a TSV of every published file (relative to `output-dir`), its byte size, and its budget (`-` in frame mode). |
| `count`    | Number of files published. |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/compose-media@v3.2.0 # v3.2.0
  id: stills
  with:
      mode: stills
      input-dir: fastlane/screenshots/raw/ios/iphone-17-pro-max
      output-dir: packages/landing/public/media
      output-template: '{slug}/{dir}/{name}@2x'
      max-avif-bytes: '45000'

- uses: rnw-community/mobile-ci/actions/compose-media@v3.2.0 # v3.2.0
  with:
      mode: frame
      input-dir: fastlane/screenshots/raw/ios/ipad-pro-13-inch-m4
      output-dir: fastlane/screenshots/framed/ipad
      device: ipad
      background: '#F8F8F8-#F1F1F1'
      fit: '0.78'
```

## Running the scripts locally

```bash
scripts/media/compose-web-media.sh --input-dir raw/ios/iphone-17-pro-max --output-dir out \
    --output-template '{slug}/{dir}/{name}@2x' --dry-run
scripts/media/compose-web-clips.sh --help
```

To use the framing primitives from your own composer, source `frame-device.sh`.
It keeps budgie's interface: `resolve_frameit_frames_dir`,
`resolve_device_frames` (`IPHONE_*`/`IPAD_*`), and
`frame_capture <src> <frame> <x> <y> <w> <h> <out>`, which needs `WORK_ROOT`.
It also adds `frame_device_select <device> <portrait|landscape>` (`DEVICE_FRAME`,
`DEVICE_CUTOUT_*`) and `frame_device_compose`. To fetch the scripts at a pinned
tag (they source each other, so fetch all of them):

```bash
ref=<tag>
dir="${TMPDIR:-/tmp}/mobile-ci-media-$ref"
mkdir -p "$dir"
for f in media-common.sh frame-device.sh compose-web-media.sh compose-web-clips.sh; do
    curl -fsSL "https://raw.githubusercontent.com/rnw-community/mobile-ci/$ref/scripts/media/$f" -o "$dir/$f"
done
```
