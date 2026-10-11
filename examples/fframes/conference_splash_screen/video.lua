-- fframes' conference-splash-screen example: sponsor scene (3.8 s) + speaker scene (4 s)
-- for one talk, 1920x1080 @ 24 fps over track.mp3 (7.71 s).
--
--     onimite render examples/fframes/conference_splash_screen/video.lua -o splash.mp4
--
-- The talk: `--set talk=3` (a 0-based index, as fframes' `--talk 3`) or a
-- case-insensitive part of the speaker's name (`--set talk=emma`); see README.md
-- for rendering every talk with `--batch`.
local TALK = props.talk or 0

-- The talks of fframes' sessions.json.
local TALKS = {
  { speaker = "Thibaut Mattio", title = "A Vision for OCaml in the AI Era", abstract = "OCaml my Caml this talk is great. Sit back and enjoy!", avatar = "thibaut.jpg", social = "https://github.com/tmattio, https://twitter.com/tmattio_" },
  { speaker = "Adam Cholewiński", title = "Purely functional gRPC and HTTP/2 with OCaml", abstract = "OCaml my Caml this talk is great. Sit back and enjoy!", avatar = "adam.jpg", social = "https://github.com/adamchol, https://twitter.com/adamchol_" },
  { speaker = "Nathan Taylor", title = "From OCaml 4 to 5 and from Parmap to Effects: A legacy code transition story", abstract = "OCaml 5's support for shared memory parallelism and effects-based concurrency opens up new ways for developers to build new OCaml programs for modern hardware, but it isn't trivial to migrate existing software to this new world.  We've spent the last few months porting a large (~3MM LoC) OCaml codebase from process-based parallelism to multi-domain Eio, and learned a lot along the way.  In this talk, we'll discuss the fundamentals of shared-memory parallism, our incremental migration approach which used a combination of static and dynamic analysis, the pitfalls (both expected and unexpected) that we encountered along the way, and some lessons that others can adopt for their own journey.", avatar = "nathan.jpg", social = nil },
  { speaker = "Tikhon Jelvis", title = "Analyzing Programs with SMT Solvers", abstract = "We can use SMT solvers like Z3 to analyze programs and answer difficult questions about our code. By generating and solving complex constraints, we can improve error message localization, attack cryptographic protocols, check refinement types, search for proofs, verify invariants, compare programs against specifications or even synthesize code. Z3 is the goto state-of-the-art SMT solver, available under and open source license and has a first-class OCaml library.\n\nIn this talk, I'll walk through a simple OCaml program to generate SMT constraints that represent a bounded model of programs in a simple imperative language. Algebraic data types and pattern matching are a perfect fit for this kind of work.", avatar = "tikhon.jpg", social = "https://github.com/TikhonJelvis" },
  { speaker = "Dmitriy Kovalenko", title = "0xCaml From a System Engineer's Point of View", abstract = "I do a lot of Rust, C, Zig and whatever else cursed systems programming languages are there. So recently 0xCaml popped out and I was def interested if I can finally use it. So I did some research on how it actually works comparing to native OCaml and other languages and try to build odiff (the fastest image comparison lib in the world) with 0xCaml. Here is what I learned.", avatar = "dmitriy.jpg", social = "https://github.com/dmtrKovalenko, https://twitter.com/goose_plus_plus" },
  { speaker = "Malcolm Matalka", title = "Frameworks: No, Libraries: Yes. Developing a product in OCaml from Scratch", abstract = "Terrateam is an open source infrastructure management product written in OCaml. In order to stay lean and flexible, Terrateam has developed almost all of its own frameworks and tooling. With a small team, the Terrateam product punches well above its weight compared to its competition. This talk will cover the choice to develop their own frameworks, the good, the bad, and how OCaml has been instrumental in being able to achieve so much despite being a two person company.", avatar = "malcolm.jpg", social = nil },
  { speaker = "Emma Jin", title = "Performance Pitfalls: Tales From a Python/OCaml Codebase", abstract = "Semgrep is a tool that enables developers to search their code for security vulnerabilities, built with an OCaml engine and a Python frontend. This has come with a fair amount of performance pain. In this talk, I'll share some of the worst problems we ran into, how we found them, and how we solved them (mostly, rewriting Python code in OCaml).", avatar = "emma.jpg", social = nil },
  { speaker = "Nicolás Ojeda Bär", title = "OCaml at LexiFi", abstract = "[LexiFi](https://www.lexifi.com/) is likely to have been the first real industrial user of OCaml, back when it was funded in 2000. In this talk, I will present some of the things we have learned along the way. Some of the points I will address: our technology stack (development environment, deployment and distribution, cloud infrastructure, etc), tooling, strong and weak points of OCaml, people aspects (hiring and training), etc. If there is time, I will also present one of our key technical innovations: extending the OCaml compiler with type reflection (this topic will be explored further in the dedicated Workshop).", avatar = "nicolas.jpg", social = nil },
  { speaker = "Xavier Van de Woestyne", title = "Generating Static Websites the Functional Programming Way", abstract = "Static site generators like Jekyll, Zola, and Hugo are effective, but fall short for complex sites like personal encyclopedias, wikis, or sites with rich content. Features like *backlinks* and *transclusions* require richer context and efficient builds. This talk explores the theory behind static site generation (as a case of *build systems*) and shows how to implement advanced features inspired by [Project Xanadu](https://www.xanadu.net/) using [YOCaml](https://github.com/xhtmlboi/yocaml), a static site framework based on functional abstractions (such as strong profunctors) in OCaml.", avatar = "xavier.jpg", social = nil },
  { speaker = "Mindy Preston", title = "I Can See The Pixels: Designing Cross-Stitch Patterns in OCaml", abstract = "I was unsatisfied with existing cross-stitch pattern generating software, which was mostly structured like pixel-based paint programs. Those programs with support for very common operations like tiling borders were locked behind paywalls. I decided to write my own in OCaml, and I've been using it to design cross-stitch patterns since 2019. I'll talk a bit about the joy of making the Exact Right Tool, the anguish of abandoned experiments, and the ambiguous pleasure of monetizing art.", avatar = "mindy.jpg", social = "https://github.com/yomimono" },
  { speaker = "Paul-Elliot Anglès d'Auriac", title = "Slipshow: A Full-Featured Presentation Tool in OCaml", abstract = "Slipshow is a tool to create interactive presentations. Started as a JavaScript project, it is now fully written in OCaml and features a runtime engine, a compiler, a collaborative editing website, a VSCode extension, a standalone app...\n\nThis talk tells the story of how it is possible to develop and maintain such a challenging project as a single developer.\n\nIf you are reading this far into the abstract, I suspect you are going to FUN OCaml? Are you giving a talk? If so, consider (re)writing your presentation in Slipshow!", avatar = "paul-elliot.jpg", social = nil },
}

local function find_talk(q)
  if type(q) == "number" then return TALKS[q + 1] end
  q = q:lower()
  for _, t in ipairs(TALKS) do
    if t.speaker:lower():find(q, 1, true) then return t end
  end
end
local talk = assert(find_talk(TALK), "no such talk")

local W, H = 1920, 1080
local CAMEL_PATH = "M663.134 750.24C660.25 738.885 666.014 724.693 660.25 713.341C657.367 701.986 648.72 701.986 645.84 693.471C634.31 670.763 619.899 645.219 619.899 616.833C619.899 594.125 611.252 571.418 608.372 548.711C608.372 537.356 608.372 526.004 608.372 514.648C608.372 508.972 608.372 503.296 605.489 497.62C605.489 494.781 605.489 489.105 602.605 489.105L605.489 480.589C605.489 477.749 631.429 477.749 640.076 477.749C654.487 477.749 666.014 477.749 680.424 480.589C709.248 480.589 732.305 480.589 761.126 477.749C821.651 469.234 847.592 443.69 862.002 435.174C916.764 398.275 942.704 332.99 942.704 332.99C951.351 313.122 951.351 276.22 971.525 262.028C994.583 242.16 1032.05 244.997 1057.99 233.645C1072.4 227.969 1083.93 222.29 1101.23 225.129C1112.75 227.969 1132.93 242.16 1138.69 222.29C1135.81 219.453 1132.93 216.613 1130.05 213.774C1153.1 210.937 1130.05 162.683 1121.4 151.331C1106.99 137.136 1086.81 128.621 1063.75 122.945C1034.93 114.429 1009 105.913 983.055 111.593C936.941 120.108 939.821 94.5612 913.884 94.5612C882.179 94.5612 824.535 97.4008 813.004 128.621C807.241 142.815 804.361 142.815 795.714 154.168C789.947 162.683 795.714 171.199 792.831 182.551C789.947 193.906 784.184 233.645 778.42 247.836C769.773 270.544 758.243 298.927 738.069 298.927C709.248 301.767 686.191 304.606 663.134 296.091C648.72 290.415 625.663 281.899 614.136 279.059C559.374 256.352 550.727 233.645 550.727 233.645C544.964 225.129 530.553 208.098 524.787 188.23C519.023 165.523 507.493 148.492 504.613 137.136C498.849 125.784 490.202 105.913 481.555 86.0456C470.025 60.4987 455.615 40.6309 444.088 32.1153C426.794 17.9236 412.383 -4.7837 377.796 0.892351C372.032 0.892351 348.975 3.73194 331.681 17.9236C320.151 26.4393 317.271 46.307 305.741 63.3383C299.977 71.8539 288.447 100.237 279.803 122.945C274.037 139.976 271.156 151.331 262.509 157.007C256.743 162.683 250.979 168.359 242.332 165.523C236.569 162.683 230.805 159.844 225.042 157.007C216.394 151.331 199.1 120.108 187.572 100.237C178.925 80.3695 158.75 51.983 147.221 37.7914C129.928 15.084 121.282 9.40799 95.342 9.40799C43.4626 9.40799 37.6982 37.7914 14.6409 80.3695C3.11221 100.237 0.22982 128.621 -19.9454 151.331C-28.592 162.683 -66.0603 216.613 -92 225.129V616.833V613.996C-89.1178 608.317 -89.1178 602.641 -86.2356 599.802C-74.7069 579.934 -51.6496 560.066 -40.1206 537.356C-34.3564 526.004 -25.7099 514.648 -19.9454 500.457C-17.0633 491.941 -14.1809 474.913 -8.41675 466.397C-2.65227 455.042 8.87639 452.205 20.4053 449.366C40.5806 446.526 54.9913 474.913 78.0489 486.265C86.6955 491.941 132.81 506.136 147.221 508.972C170.279 514.648 193.336 517.488 216.394 523.164C227.922 526.004 239.452 526.004 253.863 528.843C265.39 528.843 308.624 531.68 308.624 534.519C288.447 545.871 274.037 574.258 265.39 596.965C256.743 619.672 250.979 645.219 242.332 665.087C230.805 687.794 207.747 699.15 210.629 727.533C210.629 738.885 213.512 750.24 210.629 761.592C207.747 775.787 201.983 784.303 199.1 798.495C193.336 815.523 187.572 869.453 181.807 883.648L227.922 877.969C233.685 866.617 236.569 815.523 239.452 809.847C248.099 784.3 259.626 764.432 276.92 744.564C294.214 724.693 294.214 701.986 302.861 679.279C314.388 653.732 328.798 636.704 343.208 613.996C369.149 574.258 386.443 520.327 438.321 508.972C444.088 508.972 475.792 531.68 490.202 545.871C507.493 562.903 524.787 579.934 536.317 602.641C556.491 645.219 576.668 707.662 582.431 738.885C585.315 758.756 588.195 758.756 602.605 775.787C608.372 781.463 619.899 804.171 625.663 812.686C628.546 821.202 637.193 841.07 640.076 852.425C642.956 858.101 651.603 877.969 657.367 895H700.601C683.308 846.746 668.897 798.495 663.134 750.24Z"
local SP_SLOW = spring { mass = 4, stiffness = 30, damping = 25 }
local SP_DASH = spring { mass = 4, stiffness = 80, damping = 55 }
local SP_RISE = spring { mass = 0.8, stiffness = 100, damping = 16 }

local function ramp(f, a, b) return animate(f, { { a, b, 0, 1, linear } }) end
-- spring progress 0 -> 1 starting at `start`
local function spr(f, start, easing) return animate(f, { { start = start, from = 0, to = 1, easing = easing } }) end

-- The talk's layout, measured at load: title and abstract wrapped
-- (fframes' text_break_lines, which drops blank lines), lines
-- `trunc(1.2 * size)` apart.
local function wrap(str, font, size, weight, width)
  local lines = {}
  for _, l in ipairs(text_lines { str, font = font, size = size, weight = weight, max_width = width }) do
    if l ~= "" then lines[#lines + 1] = l end
  end
  return lines
end
local LAYOUT = (function()
  local title_size = (#talk.title < 50 or #talk.abstract <= 300) and 70 or 56
  local abs_size = #talk.abstract > 600 and 32 or (#talk.abstract > 300 and 36 or 48)
  local title_lines = wrap(talk.title, "Inter 18pt", title_size, 800, 970)
  local title_h = #title_lines * math.floor(1.2 * title_size)
  local abs_lines = wrap(talk.abstract, "Inter 24pt", abs_size, 400, 1000)
  return {
    title_size = title_size, title_lines = title_lines,
    abs_size = abs_size, abs_lines = abs_lines, abstract_y = 350 + title_h,
    abs_h = #abs_lines * math.floor(1.2 * abs_size),
    name_w = text_width { talk.speaker, font = "Inter 24pt", size = 54, weight = 700 } + 32,
  }
end)()

local function draw_lines(lines, x, y, font, size, weight)
  local step = math.floor(1.2 * size)
  for i, line in ipairs(lines) do
    text { line, x = x, y = y + (i - 1) * step, font = font, size = size, weight = weight, fill = "#ffffff" }
  end
end

video { width = W, height = H, fps = 24, background = "#000000",
  duration = { audio = "track.mp3" },
  audio = { { "track.mp3", start = 0 } },
  render = function(f) render_scenes(f) end,
}

scene { "Sponsors", duration = 3.8, render = function(f)
  image { src = "background_gradient.jpg", x = 0, y = 0, w = W, h = H, fit = "fill" }

  -- "Warsaw 2025"
  local k = spr(f, 0.4, SP_SLOW)
  text { x = 0.7 * W, y = 0.12 * H, size = 70, fill = "#ffffff",
    opacity = animate(f, { { 2.0, 2.2, 0, 1, linear } }),
    transform = translate(0, 200 * k),
    spans = { { "Warsaw ", "Montserrat", 70, 600 }, { "2025", "JetBrains Mono", 70, 400 } } }

  -- "FUN OCaml"
  text { x = 0.5 * W, y = 0.5 * H, align = "center", baseline = "middle", size = 200,
    fill = "#ffffff", transform = translate(320 * k, -350 * k),
    spans = { { "FUN ", "Montserrat", 200, 400 }, { "OCaml", "Montserrat", 200, 400, fill = "#C24F1E" } } }

  -- OCaml camel silhouette (nested svg y=250, 1140x828, clips its overflow)
  group({ transform = translate(0, 250) }, function()
   group({ clip = { x = 0, y = 0, w = 1140, h = 828 } }, function()
    path { d = CAMEL_PATH, fill = "#562F1F", opacity = animate(f, { { 1.0, 2.5, 0, 1, linear } }) }
   end)
  end)

  text { "Sponsors and Partners", x = 0.5 * W, y = 620, font = "Inter 18pt", size = 60, weight = 600,
    fill = "#d43f00", baseline = "middle", opacity = animate(f, { { 1.2, 1.4, 0, 1, linear } }) }
  group({ transform = translate(0, 600 * (1 - spr(f, 1.2, SP_RISE))) }, function()
    image { src = "sponsors.png", x = 720, y = 670, w = 1150, h = 1150 * 338 / 1008, fit = "fill" }
  end)
end }

scene { "Speaker", duration = 4, render = function(f)
  local L = LAYOUT
  local tilt = animate(f, {
    { 0.3, 2.3, 0.4, 1.2, linear },
    { 2.3, 4.1, 1.2, 0.8, linear },
  })
  local dash = 300 * (1 - spr(f, 0, SP_DASH))

  -- background_2025.png: width 1920, height auto (1901x1164 source)
  image { src = "background_2025.png", x = 0, y = 0, w = W, h = W * 1164 / 1901, fit = "fill" }

  draw_lines(L.title_lines, 90, 350, "Inter 18pt", L.title_size, 800)

  group({ transform = translate(1000, 250) }, function()
   group({ clip = { x = 0, y = 0, w = 140, h = 134 } }, function()
    path { d = "M-4.94719e-06 2H134.8C136.567 2 138 3.43269 138 5.2V134", fill = "none", stroke = "#FFFBFB",
      stroke_width = 3, stroke_dasharray = { 300 }, stroke_dashoffset = dash }
   end)
  end)
  group({ transform = translate(40, L.abstract_y + L.abs_h - 110) }, function()
   group({ clip = { x = 0, y = 0, w = 140, h = 134 } }, function()
    path { d = "M137.2 132H5.19999C3.43268 132 2 130.567 2 128.8V0", fill = "none", stroke = "#FFFBFB",
      stroke_width = 3, stroke_dasharray = { 300 }, stroke_dashoffset = dash }
   end)
  end)

  draw_lines(L.abs_lines, 90, L.abstract_y, "Inter 24pt", L.abs_size, 400)

  -- speaker card, skewed by the tilt angle
  group({ transform = { skew = { tilt, -tilt + 0.4 } } }, function()
    group({ shadow = { dx = 3, dy = 3, blur = 8, color = "#000000", opacity = 0.5 } }, function()
      rect { x = 1200, y = 162, w = 661, h = 770, rx = 60, ry = 60, fill = "#525764" }
    end)
    -- circle filled with the avatar (pattern viewBox 0 0 480 480 over the 440x440 bbox)
    group({ clip_path = "M1320 470 a220 220 0 1 0 440 0 a220 220 0 1 0 -440 0" }, function()
      image { src = talk.avatar or "speaker_placeholder.png", x = 1320, y = 250, w = 440, h = 440, fit = "contain" }
    end)
    rect { x = 1534 - L.name_w / 2, y = 820 - 95 / 2, w = L.name_w, h = 90, rx = 20, ry = 20, fill = "#ffffff" }
    text { talk.speaker, x = 1534, y = 820, align = "center", baseline = "middle", fill = "#D54000",
      font = "Inter 24pt", size = 54, weight = 700 }
  end)
end }
