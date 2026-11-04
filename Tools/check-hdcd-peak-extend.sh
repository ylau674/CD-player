#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/cdplayer-hdcd-peak-extend.XXXXXX")
cleanup() {
    rm -f "$work_dir/peak-extend.wav" "$work_dir/input.s16le" \
        "$work_dir/ffmpeg.s32le" "$work_dir/app.s32le"
    rmdir "$work_dir"
}
trap cleanup EXIT HUP INT TERM

for command in ffmpeg python3 swift cmp; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'Required command not found: %s\n' "$command" >&2
        exit 1
    }
done

python3 "$repo_root/Tools/make-hdcd-peak-extend-test.py" "$work_dir/peak-extend.wav"
ffmpeg -nostdin -hide_banner -loglevel error -i "$work_dir/peak-extend.wav" \
    -map 0:a:0 -c:a pcm_s16le -f s16le "$work_dir/input.s16le"
ffmpeg -nostdin -hide_banner -loglevel error -i "$work_dir/peak-extend.wav" \
    -map 0:a:0 -af hdcd -c:a pcm_s32le -f s32le "$work_dir/ffmpeg.s32le"
swift run --package-path "$repo_root/Packages/CDKit" HDCDCheck \
    "$work_dir/input.s16le" "$work_dir/app.s32le"
cmp "$work_dir/ffmpeg.s32le" "$work_dir/app.s32le"
python3 - "$work_dir/input.s16le" "$work_dir/app.s32le" <<'PY'
import array
import sys

source = array.array("h")
with open(sys.argv[1], "rb") as stream:
    source.frombytes(stream.read())
decoded = array.array("i")
with open(sys.argv[2], "rb") as stream:
    decoded.frombytes(stream.read())
if sys.byteorder == "big":
    source.byteswap()
    decoded.byteswap()

source_peak = max(abs(sample) for sample in source)
decoded_peak = max(abs(sample) for sample in decoded)
linear_peak = source_peak * 32_768
print(f"Input peak: {source_peak}/32768 ({100 * source_peak / 32768:.1f}% FS)")
print(f"Decoded peak: {decoded_peak}/2147483648 ({100 * decoded_peak / 2147483648:.1f}% FS)")
print(f"No-Peak-Extend 16-to-32-bit peak: {linear_peak}")
if decoded_peak <= linear_peak:
    raise SystemExit("Peak Extend did not restore the synthetic high-level peak.")
if decoded_peak >= 2_147_483_647:
    raise SystemExit("Synthetic Peak Extend output clipped.")
PY
printf 'Synthetic Peak Extend output matches FFmpeg bit for bit and restores headroom without clipping.\n'
