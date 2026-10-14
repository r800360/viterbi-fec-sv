#!/bin/bash
# install-tools.sh - the toolchain behind every result in this repository, pinned to the versions the committed
# results were produced with. Used by the Dockerfile and by GitHub Actions; run as root on Ubuntu 26.04.
#   Icarus Verilog 12.0, Verilator 5.032, Yosys 0.52 (+ ABC, yosys-smtbmc), Z3 4.13.3, SymbiYosys 0.52 (from git),
#   nextpnr-ice40 0.9 with its chip database, IceStorm (icetime), Graphviz 14.1.2, Python 3, make, g++
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  iverilog=12.0-3 \
  verilator=5.032-1 \
  yosys=0.52-2 yosys-abc=0.52-2 \
  z3=4.13.3-1build1 \
  nextpnr-ice40=0.9-3 nextpnr-ice40-chipdb=0.9-3 \
  fpga-icestorm fpga-icestorm-chipdb \
  graphviz=14.1.2-1ubuntu1 \
  python3 make g++ git ca-certificates
# SymbiYosys is not packaged for Ubuntu 26.04: build the release that matches Yosys 0.52
if ! command -v sby > /dev/null; then
  # v0.52 is an annotated tag; fetch the commit it points to, so the version cannot move
  git -c init.defaultBranch=main init -q /tmp/sby
  git -C /tmp/sby fetch -q --depth 1 https://github.com/YosysHQ/sby.git 1b36b27d90c99f4bd8c732532ccd88e361d5b5d9
  git -C /tmp/sby checkout -q FETCH_HEAD
  make -C /tmp/sby install PREFIX=/usr/local > /dev/null
  rm -rf /tmp/sby
fi
echo "== toolchain"
iverilog -V 2>&1 | sed -n 1p
verilator --version
yosys -V
z3 --version
sby --help > /dev/null && echo "SymbiYosys v0.52"
nextpnr-ice40 --version 2>&1 | sed -n 1p
dot -V 2>&1
python3 --version
