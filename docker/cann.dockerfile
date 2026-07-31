# syntax=docker/dockerfile:1
ARG BASE_IMAGE=python:3.10
FROM ${BASE_IMAGE}

ARG CANN_VERSION=8.0.RC1
ARG CHIP_TYPE="910b"
ARG DRIVER_VERSION="24.1.1"
ARG INSTALL_COMPONENTS=toolkit,kernels

ENV DEBIAN_FRONTEND=noninteractive

USER root

# CANN .run installers need these at install time; the toolkit installer also
# probes for a working python3 to place its site-packages.
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc g++ make cmake zlib1g-dev pciutils net-tools \
    && rm -rf /var/lib/apt/lists/*

# numpy must stay <2: CANN 8.0.RC1's tbe uses np.float_, removed in NumPy 2.0.
RUN pip install --no-cache-dir attrs "numpy<2" decorator sympy cffi pyyaml \
        pathlib2 psutil protobuf scipy requests absl-py

# Install CANN via BuildKit bind mount (packages never enter an image layer)
RUN --mount=type=bind,source=packages/${CANN_VERSION},target=/tmp/packages \
    cd /tmp/packages && \
    export LD_LIBRARY_PATH="" && \
    export PYTHONPATH="" && \
    export DRIVER_VERSION=${DRIVER_VERSION} && \
    if echo "${INSTALL_COMPONENTS}" | grep -q "nnae"; then \
        ./Ascend-cann-nnae_${CANN_VERSION}_linux*.run --install --quiet; \
    elif echo "${INSTALL_COMPONENTS}" | grep -q "toolkit"; then \
        ./Ascend-cann-toolkit_${CANN_VERSION}_linux*.run --install --quiet; \
    fi && \
    . /usr/local/Ascend/ascend-toolkit/set_env.sh && \
    if echo "${INSTALL_COMPONENTS}" | grep -q "kernels"; then \
        ./Ascend-cann-kernels-${CHIP_TYPE}_${CANN_VERSION}_linux*.run --install --quiet; \
    fi && \
    if echo "${INSTALL_COMPONENTS}" | grep -q "nnal"; then \
        ./Ascend-cann-nnal_${CANN_VERSION}_linux*.run --install --quiet; \
    fi && \
    echo "CANN installation completed"

# CANN Toolkit Environment
ENV ASCEND_TOOLKIT_HOME=/usr/local/Ascend/ascend-toolkit/latest \
    ASCEND_AICPU_PATH=/usr/local/Ascend/ascend-toolkit/latest \
    ASCEND_OPP_PATH=/usr/local/Ascend/ascend-toolkit/latest/opp \
    TOOLCHAIN_HOME=/usr/local/Ascend/ascend-toolkit/latest/toolkit \
    ASCEND_HOME_PATH=/usr/local/Ascend/ascend-toolkit/latest
ENV LD_LIBRARY_PATH=${ASCEND_TOOLKIT_HOME}/lib64:${ASCEND_TOOLKIT_HOME}/lib64/plugin/opskernel:${ASCEND_TOOLKIT_HOME}/lib64/plugin/nnengine:${ASCEND_TOOLKIT_HOME}/opp/built-in/op_impl/ai_core/tbe/op_tiling/lib/linux/aarch64:${ASCEND_TOOLKIT_HOME}/tools/aml/lib64:${ASCEND_TOOLKIT_HOME}/tools/aml/lib64/plugin
ENV PYTHONPATH=${ASCEND_TOOLKIT_HOME}/python/site-packages:${ASCEND_TOOLKIT_HOME}/opp/built-in/op_impl/ai_core/tbe
ENV PATH=${ASCEND_TOOLKIT_HOME}/bin:${ASCEND_TOOLKIT_HOME}/compiler/ccec_compiler/bin:${ASCEND_TOOLKIT_HOME}/tools/ccec_compiler/bin:${PATH}

# Ascend Driver Environment (host-mounted at runtime via device plugin)
ENV ASCEND_DRIVER_HOME=/usr/local/Ascend/driver
ENV LD_LIBRARY_PATH=${LD_LIBRARY_PATH}:${ASCEND_DRIVER_HOME}/lib64:${ASCEND_DRIVER_HOME}/lib64/driver
ENV PATH=${PATH}:${ASCEND_DRIVER_HOME}/bin

# Persist env vars for login shells (SSH) and non-login interactive shells (docker exec bash)
# Write our own env script instead of sourcing set_env.sh to:
#   - guarantee consistency with the ENV declarations above
#   - avoid duplicate PATH entries on repeated shell invocations
RUN { \
    echo '# CANN Toolkit'; \
    echo 'export ASCEND_TOOLKIT_HOME=/usr/local/Ascend/ascend-toolkit/latest'; \
    echo 'export ASCEND_AICPU_PATH=$ASCEND_TOOLKIT_HOME'; \
    echo 'export ASCEND_OPP_PATH=$ASCEND_TOOLKIT_HOME/opp'; \
    echo 'export TOOLCHAIN_HOME=$ASCEND_TOOLKIT_HOME/toolkit'; \
    echo 'export ASCEND_HOME_PATH=$ASCEND_TOOLKIT_HOME'; \
    echo 'export LD_LIBRARY_PATH=$ASCEND_TOOLKIT_HOME/lib64:$ASCEND_TOOLKIT_HOME/lib64/plugin/opskernel:$ASCEND_TOOLKIT_HOME/lib64/plugin/nnengine:$ASCEND_TOOLKIT_HOME/opp/built-in/op_impl/ai_core/tbe/op_tiling/lib/linux/aarch64:$ASCEND_TOOLKIT_HOME/tools/aml/lib64:$ASCEND_TOOLKIT_HOME/tools/aml/lib64/plugin'; \
    echo 'export PYTHONPATH=$ASCEND_TOOLKIT_HOME/python/site-packages:$ASCEND_TOOLKIT_HOME/opp/built-in/op_impl/ai_core/tbe'; \
    echo ''; \
    echo '# Ascend Driver (host-mounted at runtime)'; \
    echo 'export ASCEND_DRIVER_HOME=/usr/local/Ascend/driver'; \
    echo 'export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$ASCEND_DRIVER_HOME/lib64:$ASCEND_DRIVER_HOME/lib64/driver'; \
    echo ''; \
    echo '# PATH (with dedup guard)'; \
    echo 'case ":$PATH:" in *":$ASCEND_TOOLKIT_HOME/bin:"*) ;; *) export PATH=$ASCEND_TOOLKIT_HOME/bin:$ASCEND_TOOLKIT_HOME/compiler/ccec_compiler/bin:$ASCEND_TOOLKIT_HOME/tools/ccec_compiler/bin:$PATH ;; esac'; \
    echo 'case ":$PATH:" in *":$ASCEND_DRIVER_HOME/bin:"*) ;; *) export PATH=$PATH:$ASCEND_DRIVER_HOME/bin ;; esac'; \
    } > /etc/profile.d/ascend.sh && \
    cp /etc/profile.d/ascend.sh /etc/ascend-env.sh && \
    echo '. /etc/ascend-env.sh' >> /etc/bash.bashrc

# Hardware Metadata Labeling
LABEL com.ascend.chip=${CHIP_TYPE} \
      com.ascend.driver.version=${DRIVER_VERSION} \
      com.ascend.cann.version=${CANN_VERSION}

CMD ["/bin/bash"]
