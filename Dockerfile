FROM rockylinux:8

# Install Python 3 + scientific libraries needed by ras_preprocess.py
RUN dnf install -y python3 python3-pip gdal python3-gdal && \
    pip3 install numpy scipy h5py && \
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
