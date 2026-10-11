#!/bin/sh
# Regenerates the examples' generated media and the decoder test clips
# (testdata/*.mp4): every sound, voice, video clip and photo under
# examples/ that is not a font, an SVG, a Lottie file or a caption file
# comes from here (except examples/fframes/, whose media
# examples/fframes/fetch.sh copies from fframes). onimite renders the pictures and
# synthesizes the sounds (the .lua scripts beside this file); ffmpeg only
# converts them to the formats the examples demonstrate, and espeak-ng
# speaks the voice lines. Neither is an onimite dependency.
#
#     tools/gen_media/gen.sh            # needs build/onimite (or $ONIMITE), ffmpeg, espeak-ng
#
# What it writes:
#
#   examples/audio_demo/media   music.mp3 (sounds.lua), pop.wav, whoosh.ogg,
#                               vo.wav, vo2.m4a (espeak-ng)
#   examples/media_demo/media   music.mp3, clip.mp4 (clip.lua; subs.vtt is written by hand)
#   examples/suite/media        transparent.mov (ProRes 4444), avatar_vp9_alpha.webm
#                               (VP9 + alpha), both mascot.lua; canyon.webp (canyon.lua)
#   examples/why_onimite/media  transparent.mov
#   examples/onimite_saga/media transparent.mov
#   examples/social_clip_kit/media  mascot.webm
#   testdata                    clip_baseline.mp4 (H.264 Constrained Baseline + mono AAC),
#                               clip_high.mp4 (H.264 High, B-frames, no audio): clip.lua's
#                               first 3 s at 320x240, a keyframe every 15 frames, for the
#                               decoder tests in encode/video_decode_test.odin
#
# The voice lines are espeak-ng placeholders, to be replaced by better
# synthesized speech (e.g. Gemini TTS) with the same words and lengths.
#
# All of it is part of this repository (MIT), like the scripts.

set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE="$ROOT/tools/gen_media"
OF=${ONIMITE:-"$ROOT/build/onimite"}
EX="$ROOT/examples"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT

FF="ffmpeg -v error -y"

echo "sounds"
for s in music pop whoosh; do
	"$OF" audio render "$HERE/sounds.lua" --set sound=$s -o "$TMP/$s.wav"
done
$FF -i "$TMP/music.wav" -c:a libmp3lame -b:a 128k "$EX/audio_demo/media/music.mp3"
cp "$EX/audio_demo/media/music.mp3" "$EX/media_demo/media/music.mp3"
$FF -i "$TMP/pop.wav" -ac 1 -c:a pcm_s16le "$EX/audio_demo/media/pop.wav"
$FF -i "$TMP/whoosh.wav" -c:a libvorbis -q:a 4 "$EX/audio_demo/media/whoosh.ogg"

echo "voice (espeak-ng placeholders)"
VOICE="-v en-us+f3 -s 150 -p 45"
espeak-ng $VOICE -w "$TMP/vo.wav" "Every sound lands on the beat."
espeak-ng $VOICE -w "$TMP/vo2.wav" "Made with oh frames."
$FF -i "$TMP/vo.wav" -c:a pcm_s16le "$EX/audio_demo/media/vo.wav"
$FF -i "$TMP/vo2.wav" -c:a aac -b:a 64k "$EX/audio_demo/media/vo2.m4a"

echo "mascot (alpha clips)"
"$OF" render "$HERE/mascot.lua" -o "$TMP/mascot/"
$FF -framerate 30 -i "$TMP/mascot/%06d.png" -c:v prores_ks -profile:v 4 -pix_fmt yuva444p10le \
	-qscale:v 16 -alpha_bits 8 -vendor apl0 "$EX/suite/media/transparent.mov"
cp "$EX/suite/media/transparent.mov" "$EX/why_onimite/media/transparent.mov"
cp "$EX/suite/media/transparent.mov" "$EX/onimite_saga/media/transparent.mov"
$FF -framerate 30 -i "$TMP/mascot/%06d.png" -c:v libvpx-vp9 -pix_fmt yuva420p -b:v 0 -crf 30 \
	-row-mt 1 -auto-alt-ref 0 "$EX/suite/media/avatar_vp9_alpha.webm"
cp "$EX/suite/media/avatar_vp9_alpha.webm" "$EX/social_clip_kit/media/mascot.webm"

echo "clip"
"$OF" render "$HERE/clip.lua" --qp 26 -o "$EX/media_demo/media/clip.mp4"

echo "testdata clips"
"$OF" render "$HERE/clip.lua" 0..90 --scale 0.5 -o "$TMP/clip/"
"$OF" audio render "$HERE/clip.lua" 0..90 -o "$TMP/clip.wav"
GOP="-pix_fmt yuv420p -g 15 -keyint_min 15 -sc_threshold 0 -crf 23 -movflags +faststart"
$FF -framerate 30 -i "$TMP/clip/%06d.png" -i "$TMP/clip.wav" -c:v libx264 -profile:v baseline $GOP \
	-c:a aac -ac 1 -ar 44100 -b:a 96k -shortest "$ROOT/testdata/clip_baseline.mp4"
$FF -framerate 30 -i "$TMP/clip/%06d.png" -c:v libx264 -profile:v high -bf 2 $GOP "$ROOT/testdata/clip_high.mp4"

echo "canyon"
"$OF" frame "$HERE/canyon.lua" 0 -o "$TMP/canyon"
$FF -i "$TMP/canyon/0.png" -c:v libwebp -quality 75 -compression_level 6 "$EX/suite/media/canyon.webp"

echo "done"
