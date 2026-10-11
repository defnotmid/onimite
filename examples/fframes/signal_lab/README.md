# signal_lab

Port of fframes' `signal-lab`: four 6 s motion studies (product UI, data story,
technical explainer, closing card) over the synthesized `pulse.wav`, 1920x1080 @ 30 fps.

    onimite render examples/fframes/signal_lab/video.lua -o signal_lab.mp4

Scenes `Product`, `Data`, `System`, `Final`; the video-level `render` draws the paper
background, `render_scenes(f)`, and the progress bar/footer. The fframes `AnimationRuntime`s
become `cubic_bezier(0.16, 1, 0.3, 1)` over 0.8 s and a trailing `spring` (settles by itself).

Deviations: the footer still reads "SVG + RUST" as in the original. No engine gaps.
