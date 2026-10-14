# FEC link: verification and implementation flow (tools/flow.sh). Toolchain: scripts/install-tools.sh or Dockerfile.
.PHONY: all ci lint sim formal ber ppa figures check clean

all: lint sim formal ber ppa figures   ## everything, about 10 minutes
ci: all

lint sim formal ber ppa figures:
	bash tools/flow.sh $@

# fail if a rerun changed any committed result or figure
check:
	python3 tools/check_results.py

clean:
	rm -rf build formal/fec_*
