# Build stage
FROM ubuntu:24.04 AS builder

ENV TZ=Asia/kolkata
ENV DEBIAN_FRONTEND=noninteractive
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Install all build dependencies in a single layer
RUN apt-get update && \
    apt-get install -y \
    build-essential \
    git \
    curl \
    wget \
    libtool \
    autogen \
    autoconf \
    automake1.11 \
    pkg-config \
    m4 \
    gettext \
    bison \
    byacc \
    libxml2-dev \
    default-libmysqlclient-dev \
    libssh-dev \
    libssl-dev \
    libhiredis-dev \
    libjansson-dev \
    libmysqlclient-dev \
    && rm -rf /var/lib/apt/lists/*

# Build jansson
RUN mkdir -p /root/softwares && \
    cd /root/softwares && \
    wget https://digip.org/jansson/releases/jansson-2.13.1.tar.gz && \
    tar -zxvf jansson-2.13.1.tar.gz && \
    cd jansson-2.13.1 && \
    ./configure && \
    make && \
    make install && \
    cd /root/softwares

    # Download Kannel from git
# RUN cd /root/softwares && \
#     git clone https://github.com/diviky/kannel.git

# Copy Kannel source from build context (or use git clone below)
COPY . /root/softwares/kannel

# Build Kannel
RUN cd /root/softwares/kannel && \
    sh ./bootstrap.sh && \
    ./configure -prefix=/usr/local/kannel -with-redis -with-mysql -with-defaults=speed \
    -enable-localtime -enable-start-stop-daemon && make && \
    make bindir=/usr/local/kannel install

# Build sqlbox addon
RUN cd /root/softwares/kannel/addons/sqlbox && \
    ./bootstrap && \
    ./configure -prefix=/usr/local/kannel -with-kannel-dir=/usr/local/kannel && \
    make && \
    make bindir=/usr/local/kannel/sqlbox install

# Build opensmppbox addon
RUN cd /root/softwares/kannel/addons/opensmppbox && \
    ./bootstrap && \
    ./configure -prefix=/usr/local/kannel -with-kannel-dir=/usr/local/kannel && \
    make && \
    make bindir=/usr/local/kannel/smppbox install

# Copy example configs before cleanup
RUN mkdir -p /tmp/kannel-configs && \
    cp /root/softwares/kannel/gw/smskannel.conf /tmp/kannel-configs/kannel.conf && \
    cp /root/softwares/kannel/debian/kannel.default /tmp/kannel-configs/kannel.default && \
    cp /root/softwares/kannel/addons/sqlbox/example/sqlbox.conf.example /tmp/kannel-configs/sqlbox.conf && \
    cp /root/softwares/kannel/addons/opensmppbox/example/opensmppbox.conf.example /tmp/kannel-configs/opensmppbox.conf && \
    cp /root/softwares/kannel/addons/opensmppbox/example/smpplogins.txt.example /tmp/kannel-configs/smpplogins.txt

# Runtime stage - minimal image
FROM ubuntu:24.04

ENV TZ=Asia/kolkata
ENV DEBIAN_FRONTEND=noninteractive
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Install only runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    libxml2 \
    libmysqlclient21 \
    libssl3t64 \
    libhiredis1.1.0 \
    libjansson4 \
    ca-certificates \
    supervisor \
    jq \
    curl \
    unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /var/cache/apt/archives/*

# Install AWS CLI v2 (not in Ubuntu 24.04 apt repos)
RUN curl -sS "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# Copy Kannel binaries, libraries, and configs from builder
COPY --from=builder /usr/local/kannel /usr/local/kannel
COPY --from=builder /usr/local/lib/libjansson.so* /usr/local/lib/
COPY --from=builder /tmp/kannel-configs/kannel.conf /etc/kannel/kannel.conf
COPY --from=builder /tmp/kannel-configs/kannel.default /etc/default/kannel
COPY --from=builder /tmp/kannel-configs/sqlbox.conf /etc/kannel/sqlbox.conf
COPY --from=builder /tmp/kannel-configs/opensmppbox.conf /etc/kannel/opensmppbox.conf
COPY --from=builder /tmp/kannel-configs/smpplogins.txt /etc/kannel/smpplogins.txt

# Create necessary directories
RUN mkdir -p /etc/kannel && \
    mkdir -p /var/log/kannel && \
    mkdir -p /var/log/kannel/gateway && \
    mkdir -p /var/log/kannel/smsbox && \
    mkdir -p /var/log/kannel/wapbox && \
    mkdir -p /var/log/kannel/smsc && \
    mkdir -p /var/log/kannel/sqlbox && \
    mkdir -p /var/log/kannel/smppbox && \
    mkdir -p /var/spool/kannel && \
    chmod -R 755 /var/spool/kannel && \
    chmod -R 755 /var/log/kannel

# Set library path
ENV LD_LIBRARY_PATH=/usr/local/kannel/lib:/usr/local/lib
ENV PATH=/usr/local/kannel/bin:/usr/local/kannel/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

EXPOSE 13013 13000 2346 13015

VOLUME ["/var/spool/kannel", "/etc/kannel", "/var/log/kannel"]

CMD ["/usr/bin/supervisord"]
