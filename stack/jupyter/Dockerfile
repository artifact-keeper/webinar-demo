FROM quay.io/jupyter/minimal-notebook:python-3.12
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq \
 && rm -rf /var/lib/apt/lists/*
USER ${NB_UID}
RUN pip install --no-cache-dir "huggingface_hub[cli]"
