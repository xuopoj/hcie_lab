# No `# syntax=` directive: this file uses only stock Dockerfile features, so
# pinning an external BuildKit frontend would add a registry fetch for nothing.
ARG BASE_IMAGE=hcie/cann:8.0rc1-910b
FROM ${BASE_IMAGE}

ARG MINIFORGE_VERSION=24.3.0-0
ARG PIP_INDEX=https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple
ARG GIT_LFS_VERSION=3.5.1

ENV DEBIAN_FRONTEND=noninteractive
ENV CONDA_DIR=/opt/miniforge3
ENV NUMPY_PIN=1.26.4

USER root

# aria2 for the multi-GB model downloads; the rest are MindFormers build deps.
RUN apt-get update && apt-get install -y --no-install-recommends \
        aria2 unzip patch dos2unix libopenblas-dev libjpeg-dev \
    && rm -rf /var/lib/apt/lists/*

# git-lfs is not in Debian's repo at a usable version; install the arm64 tarball.
RUN curl -fL -o /tmp/git-lfs.tar.gz \
        "https://github.com/git-lfs/git-lfs/releases/download/v${GIT_LFS_VERSION}/git-lfs-linux-arm64-v${GIT_LFS_VERSION}.tar.gz" \
    && tar -xzf /tmp/git-lfs.tar.gz -C /tmp \
    && /tmp/git-lfs-${GIT_LFS_VERSION}/install.sh \
    && git lfs install --system \
    && rm -rf /tmp/git-lfs.tar.gz /tmp/git-lfs-${GIT_LFS_VERSION}

COPY aria2c.conf /etc/aria2/aria2c.conf
RUN touch /etc/aria2/aria2.session

# Miniforge outside /workspace so the runtime bind mount cannot shadow it.
RUN curl -fL -o /tmp/miniforge.sh \
        "https://github.com/conda-forge/miniforge/releases/download/${MINIFORGE_VERSION}/Miniforge3-${MINIFORGE_VERSION}-Linux-aarch64.sh" \
    && bash /tmp/miniforge.sh -b -p "${CONDA_DIR}" \
    && rm -f /tmp/miniforge.sh \
    && "${CONDA_DIR}/bin/conda" config --set always_yes yes \
    && "${CONDA_DIR}/bin/conda" clean -afy

ENV PATH=${CONDA_DIR}/bin:${PATH}

# The base image appends `. /etc/ascend-env.sh` to /etc/bash.bashrc, and that
# script rewrites PATH — which drops the ENV above for any interactive or
# login shell. Re-prepend conda afterwards, with the same dedup guard the
# Ascend script uses, so `conda`/`mamba` resolve in every shell flavour.
RUN printf '\n# Miniforge (must follow ascend-env.sh, which rewrites PATH)\ncase ":$PATH:" in *":%s/bin:"*) ;; *) export PATH="%s/bin:$PATH" ;; esac\n' \
        "${CONDA_DIR}" "${CONDA_DIR}" | tee -a /etc/profile.d/ascend.sh >> /etc/ascend-env.sh

# ---- mindspore env (labs 01,03,04,05,06,08) --------------------------------
# Single RUN so a wheel 404 fails the build instead of baking a half-built env.
# numpy is re-pinned last: the mindspore wheel pulls numpy 2.x, which breaks MS 2.3.
ARG MS_WHL=https://ms-release.obs.cn-north-4.myhuaweicloud.com/2.3.0rc2/MindSpore/unified/aarch64/mindspore-2.3.0rc2-cp39-cp39-linux_aarch64.whl
RUN mamba create -n mindspore python=3.9 -y \
    && . "${CONDA_DIR}/etc/profile.d/conda.sh" \
    && conda activate mindspore \
    && pip config set global.index-url "${PIP_INDEX}" \
    && pip install --no-cache-dir \
        attrs decorator sympy cffi pyyaml pathlib2 psutil protobuf \
        requests absl-py jinja2 scipy \
    && pip install --no-cache-dir \
        "${ASCEND_TOOLKIT_HOME}"/lib64/te-*-py3-none-any.whl \
        "${ASCEND_TOOLKIT_HOME}"/lib64/hccl-*-py3-none-any.whl \
    && pip install --no-cache-dir "${MS_WHL}" \
        --trusted-host ms-release.obs.cn-north-4.myhuaweicloud.com \
    && pip install --no-cache-dir "numpy==${NUMPY_PIN}" scipy \
    && conda clean -afy

# ---- pytorch env (labs 02,09,10) ------------------------------------------
# torch itself is the CPU build; the NPU backend comes from torch_npu.
ARG TORCH_VERSION=2.2.0
ARG TORCHVISION_VERSION=0.17.0
ARG TORCH_NPU_VERSION=2.2.0.post1
RUN TORCH_WHL="torch-${TORCH_VERSION}-cp39-cp39-manylinux_2_17_aarch64.manylinux2014_aarch64.whl" \
    && NPU_WHL="torch_npu-${TORCH_NPU_VERSION}-cp39-cp39-manylinux_2_17_aarch64.manylinux2014_aarch64.whl" \
    && mamba create -n pytorch python=3.9 -y \
    && . "${CONDA_DIR}/etc/profile.d/conda.sh" \
    && conda activate pytorch \
    && pip config set global.index-url "${PIP_INDEX}" \
    && pip install --no-cache-dir \
        attrs decorator sympy cffi pyyaml pathlib2 psutil protobuf \
        requests absl-py jinja2 scipy \
    && pip install --no-cache-dir \
        "${ASCEND_TOOLKIT_HOME}"/lib64/te-*-py3-none-any.whl \
        "${ASCEND_TOOLKIT_HOME}"/lib64/hccl-*-py3-none-any.whl \
    && curl -fL -o "/tmp/${TORCH_WHL}" "https://download.pytorch.org/whl/cpu/${TORCH_WHL}" \
    && curl -fL -o "/tmp/${NPU_WHL}" \
        "https://gitee.com/ascend/pytorch/releases/download/v6.0.rc1.1-pytorch${TORCH_VERSION}/${NPU_WHL}" \
    && pip install --no-cache-dir "torchvision==${TORCHVISION_VERSION}" \
    && pip install --no-cache-dir "/tmp/${TORCH_WHL}" "/tmp/${NPU_WHL}" \
    && rm -f "/tmp/${TORCH_WHL}" "/tmp/${NPU_WHL}" \
    && pip install --no-cache-dir deepspeed transformers "setuptools==65.7.0" \
    && pip install --no-cache-dir "numpy==${NUMPY_PIN}" scipy \
    && conda clean -afy

# ---- MindFormers r1.1.0 ---------------------------------------------------
# Baked at /opt so the /workspace bind mount cannot shadow it; entrypoint.sh
# symlinks it into /workspace/code/ at runtime.
RUN git clone -b r1.1.0 --depth 1 \
        https://gitee.com/mindspore/mindformers.git /opt/mindformers \
    && . "${CONDA_DIR}/etc/profile.d/conda.sh" \
    && conda activate mindspore \
    && cd /opt/mindformers \
    && bash build.sh \
    && pip install --no-cache-dir "numpy==${NUMPY_PIN}" \
    && conda clean -afy

# ---- JupyterLab -----------------------------------------------------------
# Installed ONLY in the base env. Putting it in the lab envs would pull a
# dependency tree that reintroduces numpy 2.x and breaks both frameworks.
RUN "${CONDA_DIR}/bin/pip" install --no-cache-dir --index-url "${PIP_INDEX}" \
        jupyterlab notebook

# Each lab env gets ipykernel only, and registers itself as a named kernel.
RUN . "${CONDA_DIR}/etc/profile.d/conda.sh" \
    && for env in mindspore pytorch; do \
         conda activate "$env" \
         && pip install --no-cache-dir ipykernel \
         && python -m ipykernel install --prefix="${CONDA_DIR}" \
              --name "$env" --display-name "Python 3.9 ($env)" \
         && pip install --no-cache-dir "numpy==${NUMPY_PIN}" \
         && conda deactivate; \
       done \
    && conda clean -afy

COPY entrypoint.sh start-jupyter.sh /opt/bin/
RUN chmod +x /opt/bin/entrypoint.sh /opt/bin/start-jupyter.sh

EXPOSE 8888
WORKDIR /workspace

LABEL com.hcie.image=lab \
      com.hcie.cann.version=8.0.RC1 \
      com.hcie.envs=mindspore,pytorch

ENTRYPOINT ["/opt/bin/entrypoint.sh"]
CMD ["/bin/bash"]
