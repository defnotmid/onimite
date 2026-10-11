# motion_graphics

Port of fframes' `motion-graphics` example (three binaries become three scripts, 1920x1080 @ 60 fps):

    onimite render examples/fframes/motion_graphics/video.lua   -o motion.mp4   # "I FIXED / CLAUDE CODE / (for real)", 4 s
    onimite render examples/fframes/motion_graphics/install.lua -o install.mp4  # title + typed terminal command, 10 s
    onimite render examples/fframes/motion_graphics/quote.lua   -o quote.mp4    # auto-sized quote card, 3 s (edit TEXT)

Deviations:
- "(for real)" asks for weight 300 italic; the example ships only Inter 24pt Regular and Bold, so both sides fall back to the nearest face.
