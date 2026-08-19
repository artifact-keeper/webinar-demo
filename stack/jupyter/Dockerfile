# Pinned to python-3.12's digest as of 2026-08-19, so the base image stops
# moving under the demo. Rotate deliberately: docker pull
# quay.io/jupyter/minimal-notebook:python-3.12 and take the new digest.
FROM quay.io/jupyter/minimal-notebook@sha256:5b868d38f2b454cb22abb077052d341d3d7aeec2315c296c44de3b1278425782
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*
USER ${NB_UID}
RUN pip install --no-cache-dir "huggingface_hub[cli]==1.28.0"
