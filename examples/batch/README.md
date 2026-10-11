# batch

A personalized title card (name, role, accent colour; initials instead of a photo), 1280x720
@ 30 fps, 3 s. Everything per video comes from the table `props`, with defaults, so the
script renders on its own too.

One video per row, named from the row (`{index}` is the row number from 1):

    onimite render examples/batch/video.lua --batch examples/batch/rows.json -o out/{name}.mp4
    onimite render examples/batch/video.lua --batch examples/batch/rows.csv -o out/{index}-{name}.mp4
    onimite render examples/batch/video.lua --batch examples/batch/rows.csv --only 2 --draft   # out/2.mp4
    onimite render examples/batch/video.lua --batch examples/batch/rows.json --json            # per-row results

One video from a JSON object, or from the command line:

    onimite render  examples/batch/video.lua --props examples/batch/one.json -o card.mp4
    onimite preview examples/batch/video.lua --props examples/batch/one.json
    onimite frame   examples/batch/video.lua 1.5s --set name="Ken Thompson" --set role=Unix -o frames

`rows.csv` shows quoted fields with commas and doubled quotes, and a numeric `duration`
column (2.5 becomes a number; the script still calls `tonumber` so a string works too).
Precedence: `--set` over the batch row over `--props`.
