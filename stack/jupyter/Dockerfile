# Pinned to python-3.12's digest as of 2026-08-19, so the base image stops
# moving under the demo. Rotate deliberately: docker pull
# quay.io/jupyter/minimal-notebook:python-3.12 and take the new digest.
FROM quay.io/jupyter/minimal-notebook@sha256:5b868d38f2b454cb22abb077052d341d3d7aeec2315c296c44de3b1278425782
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*
USER ${NB_UID}
# pyyaml is not a declared dependency of huggingface_hub[cli]==1.28.0, but
# its CLI (huggingface_hub/utils/_fixes.py's WeakFileLock) imports it
# unconditionally on some code paths -- `hf download` crashes with
# ModuleNotFoundError: No module named 'yaml' on a base image that doesn't
# happen to carry it transitively (verified: quay.io/jupyter/minimal-notebook
# does not). Pin it explicitly rather than rely on an undeclared transitive
# dependency that can vanish on any base-image or huggingface_hub bump.
RUN pip install --no-cache-dir "huggingface_hub[cli]==1.28.0" pyyaml
