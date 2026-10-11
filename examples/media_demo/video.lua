-- Media features: a synced video clip, WebVTT subtitles, an audio spectrum,
-- and durations / audio timestamps taken from media lengths.
-- clip.mp4 (with its own sound) and music.mp3 are made by
-- tools/gen_media/gen.sh; subs.vtt is written to match the clip.
--
--     onimite render examples/media_demo/video.lua -o media_demo.mp4

local W, H = 1280, 720

video { width = W, height = H, fps = 30, background = "#0b1020",
  audio = {
    -- The clip's own sound starts with it (frame 15 = start_from 0.5 s)...
    { "clip.mp4", start = { frame = 15 }, gain_db = -6 },
    -- ...and the music runs until the video clip's length plus 4 s.
    { "music.mp3", start = 0, stop = { video = "clip.mp4", plus = { seconds = 4 } },
      gain_db = -12, fade_out = 1.5, ducked = true },
  },
}

-- As long as the clip, plus 4 seconds.
scene { "Media", duration = { video = "clip.mp4", plus = { seconds = 4 } },
  render = function(f)
    -- The clip in a rounded card; it starts at 0.5 s and loops.
    group({ clip_path = "M180 80 h560 a24 24 0 0 1 24 24 v372 a24 24 0 0 1 -24 24 h-560 a24 24 0 0 1 -24 -24 v-372 a24 24 0 0 1 24 -24 z" }, function()
      rect { x = 156, y = 80, w = 608, h = 420, fill = "#1e293b" }
      video_frame(f, { src = "clip.mp4", x = 156, y = 80, w = 608, h = 420, start_from = 0.5, looping = true, fit = "cover" })
    end)
    local info = video_info("clip.mp4")
    if info then
      text { string.format("clip.mp4  %dx%d  %.1f fps  %.2fs", info.width, info.height, info.fps, info.duration),
        x = 180, y = 530, font = "DM Sans", size = 18, fill = "#94a3b8" }
    end

    -- Spectrum bars of the music at this frame.
    local bars = audio_spectrum(f, { src = "music.mp3", sample_size = 512, smooth = 2, window = "hann", bands = 32 })
    if bars then
      for i, v in ipairs(bars) do
        local h = math.min(math.sqrt(v / 12), 1) * 300
        rect { x = 820 + (i - 1) * 13, y = 500 - h, w = 9, h = math.max(h, 2), rx = 3, fill = "#38bdf8" }
      end
    end
    text { "music.mp3", x = 820, y = 530, font = "DM Sans", size = 18, fill = "#94a3b8" }

    -- The subtitle showing now, faded in over its first 15%.
    local cue = subtitle_at(f, "subs.vtt")
    if cue then
      local a = math.min(cue.progress / 0.15, 1)
      group({ opacity = a }, function()
        rect { x = W / 2 - 420, y = 600, w = 840, h = 64, rx = 14, fill = rgba(15, 23, 42, 0.85) }
        text { cue.text, x = W / 2, y = 642, align = "center", font = "DM Sans", size = 28, fill = "#f8fafc" }
      end)
    end
  end }
