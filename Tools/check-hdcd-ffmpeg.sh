#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sample_url=${1:-https://fate-suite.ffmpeg.org/filter/hdcd.flac}
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/cdplayer-hdcd-check.XXXXXX")
cleanup() {
    rm -f "$work_dir/hdcd.flac" "$work_dir/input.s16le" \
        "$work_dir/ffmpeg.s32le" "$work_dir/app.s32le"
    rmdir "$work_dir"
}
trap cleanup EXIT HUP INT TERM

for command in curl ffmpeg ffprobe swift cmp; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'Required command not found: %s\n' "$command" >&2
        exit 1
    }
done

curl --fail --location --silent --show-error --output "$work_dir/hdcd.flac" "$sample_url"
format=$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate,channels \
    -of csv=p=0 "$work_dir/hdcd.flac")
if [ "$format" != "44100,2" ]; then
    printf 'Expected 44.1 kHz stereo input, got: %s\n' "$format" >&2
    exit 1
fi

ffmpeg -nostdin -hide_banner -loglevel error -i "$work_dir/hdcd.flac" \
    -map 0:a:0 -c:a pcm_s16le -f s16le "$work_dir/input.s16le"
ffmpeg -nostdin -hide_banner -loglevel error -i "$work_dir/hdcd.flac" \
    -map 0:a:0 -af hdcd -c:a pcm_s32le -f s32le "$work_dir/ffmpeg.s32le"
swift run --package-path "$repo_root/Packages/CDKit" HDCDCheck \
    "$work_dir/input.s16le" "$work_dir/app.s32le"
cmp "$work_dir/ffmpeg.s32le" "$work_dir/app.s32le"
printf 'libhdcd output matches FFmpeg hdcd output bit for bit.\n'
