package onimite_app

import "core:strings"

// The onimite-video skill, built in: the MCP `guide` tool serves it, so a
// client that has no skill installed (Claude Desktop) learns the script API
// from the binary it runs, at the same version.

@(private = "file")
SKILL_FILES := #load_directory("../skills/onimite-video")

@(private = "file")
SKILL_REFERENCES := #load_directory("../skills/onimite-video/references")

// The guide's topics: "skill" (SKILL.md, the start) and each reference by
// name ("api", "audio", ...).
guide_topics :: proc(allocator := context.temp_allocator) -> []string {
	topics := make([dynamic]string, 0, 1 + len(SKILL_REFERENCES), allocator)
	append(&topics, "skill")
	for f in SKILL_REFERENCES {
		if strings.has_suffix(f.name, ".md") {
			append(&topics, strings.trim_suffix(f.name, ".md"))
		}
	}
	return topics[:]
}

// The text of guide topic `topic` ("" or "skill": SKILL.md).
guide_text :: proc(topic: string) -> (string, bool) {
	if topic == "" || topic == "skill" {
		for f in SKILL_FILES {
			if f.name == "SKILL.md" {
				return string(f.data), true
			}
		}
		return "", false
	}
	for f in SKILL_REFERENCES {
		if strings.trim_suffix(f.name, ".md") == topic {
			return string(f.data), true
		}
	}
	return "", false
}
