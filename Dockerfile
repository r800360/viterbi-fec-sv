# The pinned toolchain behind every result in this repository (CI uses the same base image and install script).
#   docker build -t viterbi-fec-sv .
#   docker run --rm -u "$(id -u):$(id -g)" -v "$PWD":/work viterbi-fec-sv make all check
FROM ubuntu:26.04@sha256:f144425ff09be612d6d9ad965196e9cdc23dae1f42110a8a11a3e9a8198759f7
COPY scripts/install-tools.sh /tmp/install-tools.sh
RUN bash /tmp/install-tools.sh && rm -rf /var/lib/apt/lists/* /tmp/install-tools.sh
WORKDIR /work
