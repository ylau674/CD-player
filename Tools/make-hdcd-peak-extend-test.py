#!/usr/bin/env python3
"""Generate a short synthetic HDCD Peak Extend test track as 44.1 kHz stereo WAV."""

import math
import pathlib
import struct
import sys
import wave


RATE = 44_100
SECONDS = 10
AMPLITUDE = 32_766
FREQUENCY = 110
# This control packet leaves 31 frames of decoder read-ahead after its 40 bits.
PACKET_INTERVAL = 71
PREFIX = 0x7DE0A5D0
CONTROL = 0x50


def packet_bits() -> list[int]:
    return [
        *((PREFIX >> shift) & 1 for shift in range(31, -1, -1)),
        *((CONTROL >> shift) & 1 for shift in range(7, -1, -1)),
    ]


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {pathlib.Path(sys.argv[0]).name} OUTPUT.wav")
    output = pathlib.Path(sys.argv[1])
    if output.exists():
        raise SystemExit(f"Refusing to overwrite existing file: {output}")

    frames = RATE * SECONDS
    bits = packet_bits()
    sample_data = bytearray()
    for frame in range(frames):
        time_seconds = frame / RATE
        envelope = min(1.0, (SECONDS - time_seconds) / 1.0)
        phase = 2 * math.pi * FREQUENCY * time_seconds + math.pi / 2
        sample = round(AMPLITUDE * envelope * math.sin(phase))
        sample &= ~1
        packet_offset = frame % PACKET_INTERVAL
        if packet_offset < len(bits):
            sample |= bits[packet_offset]
        sample_data.extend(struct.pack("<hh", sample, sample))

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("xb") as stream:
        with wave.open(stream, "wb") as wav:
            wav.setnchannels(2)
            wav.setsampwidth(2)
            wav.setframerate(RATE)
            wav.writeframes(sample_data)
    print(f"Wrote {output}: {SECONDS} s, 44.1 kHz stereo, synthetic {FREQUENCY} Hz HDCD Peak Extend signal.")


if __name__ == "__main__":
    main()
