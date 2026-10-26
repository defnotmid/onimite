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
#     tools/gen_media/gen.sh cuts       # only the parts named (below); a part named after an
#                                       # example makes the media it doesn't commit, for its
#                                       # fetch.sh, with onimite (from the PATH without a
#                                       # build) and, for the alpha clips, ffmpeg
#
# What it writes, part by part:
#
#   sounds    examples/audio_demo/media   music.mp3 (sounds.lua), pop.wav, whoosh.ogg;
#                                         examples/media_demo/media music.mp3
#   voice     examples/audio_demo/media   vo.wav, vo2.m4a (espeak-ng)
#   mascot    examples/suite/media        avatar_vp9_alpha.webm (VP9 + alpha, mascot.lua); the
#                                         same webm as social_clip_kit's mascot.webm
#   suite     examples/suite/media        transparent.mov (ProRes 4444 + alpha, mascot.lua); not
#                                         committed: examples/suite/fetch.sh runs this part
#   why_onimite, onimite_saga             the same transparent.mov, each into its own media
#                                         (their fetch.sh)
#   clip      examples/media_demo/media   clip.mp4 (clip.lua; subs.vtt is written by hand)
#   cuts      examples/cuts/media         street.mp4 (street.lua: 9:16, 60 fps), surf.mp4
#                                         (surf.lua: 24 fps), clip.mp4 (as media_demo's); not
#                                         committed: examples/cuts/fetch.sh runs this part
#   footage   examples/footage/media      the same three as cuts' (examples/footage/fetch.sh)
#   testdata  testdata                    clip_baseline.mp4 (H.264 Constrained Baseline + mono
#                                         AAC), clip_high.mp4 (H.264 High, B-frames, no audio):
#                                         clip.lua's first 3 s at 320x240, a keyframe every 15
#                                         frames, for the decoder tests in encode/video_decode_test.odin
#   canyon    examples/suite/media        canyon.webp (canyon.lua)
#   three_d   examples/three_d/media      sky.png, checker.png (three_d.lua)
#
# The voice lines are espeak-ng placeholders, to be replaced by better
# synthesized speech (e.g. Gemini TTS) with the same words and lengths.
#
# All of it is part of this repository (MIT), like the scripts.

set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE="$ROOT/tools/gen_media"
OF=${ONIMITE:-"$ROOT/build/onimite"}
[ -n "${ONIMITE:-}" ] || [ -x "$OF" ] || OF=onimite    # a release's onimite on the PATH
EX="$ROOT/examples"
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT

FF="ffmpeg -v error -y"

sounds() {
	echo "sounds"
	for s in music pop whoosh; do
		"$OF" audio render "$HERE/sounds.lua" --set sound=$s -o "$TMP/$s.wav"
	done
	$FF -i "$TMP/music.wav" -c:a libmp3lame -b:a 128k "$EX/audio_demo/media/music.mp3"
	cp "$EX/audio_demo/media/music.mp3" "$EX/media_demo/media/music.mp3"
	$FF -i "$TMP/pop.wav" -ac 1 -c:a pcm_s16le "$EX/audio_demo/media/pop.wav"
	$FF -i "$TMP/whoosh.wav" -c:a libvorbis -q:a 4 "$EX/audio_demo/media/whoosh.ogg"
}

voice() {
	echo "voice (espeak-ng placeholders)"
	VOICE="-v en-us+f3 -s 150 -p 45"
	espeak-ng $VOICE -w "$TMP/vo.wav" "Every sound lands on the beat."
	espeak-ng $VOICE -w "$TMP/vo2.wav" "Made with oh frames."
	$FF -i "$TMP/vo.wav" -c:a pcm_s16le "$EX/audio_demo/media/vo.wav"
	$FF -i "$TMP/vo2.wav" -c:a aac -b:a 64k "$EX/audio_demo/media/vo2.m4a"
}

# Pip dancing (mascot.lua) as PNGs in $TMP/mascot, rendered once a run.
mascot_frames() {
	[ -d "$TMP/mascot" ] || "$OF" render "$HERE/mascot.lua" -o "$TMP/mascot/"
}

# transparent.mov, the ProRes 4444 alpha clip suite, why_onimite and
# onimite_saga play, into $1.
alpha_mov() {
	mascot_frames
	$FF -framerate 30 -i "$TMP/mascot/%06d.png" -c:v prores_ks -profile:v 4 -pix_fmt yuva444p10le \
		-qscale:v 16 -alpha_bits 8 -vendor apl0 "$1/transparent.mov"
}

mascot() {
	echo "mascot (VP9 alpha clip)"
	mascot_frames
	$FF -framerate 30 -i "$TMP/mascot/%06d.png" -c:v libvpx-vp9 -pix_fmt yuva420p -b:v 0 -crf 30 \
		-row-mt 1 -auto-alt-ref 0 "$EX/suite/media/avatar_vp9_alpha.webm"
	cp "$EX/suite/media/avatar_vp9_alpha.webm" "$EX/social_clip_kit/media/mascot.webm"
}

clip() {
	echo "clip"
	"$OF" render "$HERE/clip.lua" --qp 26 -o "$EX/media_demo/media/clip.mp4"
}

# The three clips cuts and footage edit, into $1.
clips() {
	"$OF" render "$HERE/street.lua" --qp 32 -o "$1/street.mp4"
	"$OF" render "$HERE/surf.lua" --qp 26 -o "$1/surf.mp4"
	"$OF" render "$HERE/clip.lua" --qp 26 -o "$1/clip.mp4"
}

cuts() {
	echo "cuts clips"
	clips "$EX/cuts/media"
}

footage() {
	echo "footage clips"
	clips "$EX/footage/media"
}

suite() {
	echo "suite's alpha clip"
	alpha_mov "$EX/suite/media"
}

why_onimite() {
	echo "why_onimite's alpha clip"
	alpha_mov "$EX/why_onimite/media"
}

onimite_saga() {
	echo "onimite_saga's alpha clip"
	alpha_mov "$EX/onimite_saga/media"
}

testdata() {
	echo "testdata clips"
	"$OF" render "$HERE/clip.lua" 0..90 --scale 0.5 -o "$TMP/clip/"
	"$OF" audio render "$HERE/clip.lua" 0..90 -o "$TMP/clip.wav"
	GOP="-pix_fmt yuv420p -g 15 -keyint_min 15 -sc_threshold 0 -crf 23 -movflags +faststart"
	$FF -framerate 30 -i "$TMP/clip/%06d.png" -i "$TMP/clip.wav" -c:v libx264 -profile:v baseline $GOP \
		-c:a aac -ac 1 -ar 44100 -b:a 96k -shortest "$ROOT/testdata/clip_baseline.mp4"
	$FF -framerate 30 -i "$TMP/clip/%06d.png" -c:v libx264 -profile:v high -bf 2 $GOP "$ROOT/testdata/clip_high.mp4"
}

canyon() {
	echo "canyon"
	"$OF" frame "$HERE/canyon.lua" 0 -o "$TMP/canyon"
	$FF -i "$TMP/canyon/0.png" -c:v libwebp -quality 75 -compression_level 6 "$EX/suite/media/canyon.webp"
}

three_d() {
	echo "three_d textures"
	for t in sky checker; do
		"$OF" frame "$HERE/three_d.lua" 0 --set texture=$t -o "$EX/three_d/media/$t.png"
	done
}

PARTS="sounds voice mascot suite why_onimite onimite_saga clip cuts footage testdata canyon three_d"
[ $# -gt 0 ] || set -- $PARTS
for part do
	case $part in
	sounds | voice | mascot | suite | why_onimite | onimite_saga | clip | cuts | footage | testdata | canyon | three_d) "$part" ;;
	*) echo "gen.sh: no part $part ($PARTS)" >&2; exit 2 ;;
	esac
done
echo "done"
