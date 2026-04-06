FROM rockylinux:8

# Install Python 3 + scientific libraries needed by ras_preprocess.py
# GDAL lives in EPEL; PowerTools (CRB) provides some of its dependencies
RUN dnf install -y epel-release && \
    dnf config-manager --set-enabled powertools && \
    dnf install -y python38 python38-pip python38-devel gdal gdal-devel gcc gcc-c++ findutils sed && \
    pip3.8 install numpy scipy h5py matplotlib "GDAL==$(gdal-config --version)" && \
    alternatives --set python3 /usr/bin/python3.8 && \
    dnf clean all

# Copy the HEC-RAS distribution (bin/ + libs/) and project files into the image.
# bin/ and libs/ must be present on the build host (not committed to git).
COPY . /opt/hecras

# Make HEC-RAS binaries executable
RUN chmod +x /opt/hecras/bin/*

# Make helper scripts executable and strip Windows line endings
RUN find /opt/hecras/scripts -name "*.sh" -exec chmod +x {} \; && \
    find /opt/hecras/scripts -name "*.sh" -exec sed -i 's/\r$//' {} \;

# Expose HEC-RAS shared libraries
ENV LD_LIBRARY_PATH=/opt/hecras/libs:/opt/hecras/libs/rhel_8:/opt/hecras/libs/mkl
ENV PATH=/opt/hecras/bin:$PATH

# Mount a project directory here when running the container
WORKDIR /work
