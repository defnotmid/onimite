ODIN ?= odin
BUILD_DIR ?= build
OUT ?= $(BUILD_DIR)/onimite
# x86-64 builds target x86-64-v3 (AVX2: Haswell and later), as the releases do.
MICROARCH := $(if $(filter x86_64 amd64,$(shell uname -m)),-microarch:x86-64-v3,)
FLAGS ?= -collection:deps=.. $(MICROARCH)

build:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build . $(FLAGS) -out:$(OUT)

speed:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build . $(FLAGS) -o:speed -out:$(OUT)

run: build
	./$(OUT) $(ARGS)

test:
	@mkdir -p $(BUILD_DIR)
	@for pkg in platform ui onimite script app encode speech; do \
		$(ODIN) test $$pkg $(FLAGS) -define:OICUT_PATENTED=true -out:$(BUILD_DIR)/test_$$pkg || exit 1; \
	done

smoke: speed
	bash .github/ci.sh smoke

clean:
	@test -n "$(BUILD_DIR)" && test -n "$(OUT)"
	rm -f "$(OUT)" "$(BUILD_DIR)"/test_*

.PHONY: build speed run test smoke clean
