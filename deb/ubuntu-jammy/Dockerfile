ARG GO_IMAGE
ARG BASE_IMAGE=ubuntu:jammy
ARG DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_MIRROR=http://mirrors.aliyun.com/ubuntu
ARG DOCKER_APT_MIRROR=https://mirrors.aliyun.com/docker-ce/linux/ubuntu
ARG GOPROXY=https://goproxy.cn,direct

FROM ${GO_IMAGE} as golang

FROM ${BASE_IMAGE}

ARG UBUNTU_MIRROR
ARG DOCKER_APT_MIRROR
ARG GOPROXY

RUN sed -i "s|http://archive.ubuntu.com/ubuntu|${UBUNTU_MIRROR}|g; s|http://security.ubuntu.com/ubuntu|${UBUNTU_MIRROR}|g" /etc/apt/sources.list

RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    apt-get update &&                            \
    apt-get install -y --no-install-recommends   \
    build-essential                              \
    ca-certificates                              \
    devscripts                                   \
    equivs                                       \
    git                                          \
    wget                                         \
    pkg-config                                   \
    libnet-dev                                   \
    libseccomp2                                  \
    libseccomp-dev                               \
    iproute2                                     \
    kmod                                         \
    curl                                         \
    unzip &&                                     \
    \
    # Housekeeping
    apt-get clean -y &&                          \
    rm -rf                                       \
    /var/cache/debconf/*                         \
    /var/lib/apt/lists/*                         \
    /var/log/*                                   \
    /tmp/*                                       \
    /var/tmp/*                                   \
    /usr/share/doc/*                             \
    /usr/share/man/*                             \
    /usr/share/local/*

ARG arch
ENV ARCH=${arch}
ENV GOPATH /go
ENV PATH $PATH:/usr/local/go/bin:$GOPATH/bin:/root/.local/bin

ARG DEB_FILES
COPY ${DEB_FILES} /root/build-deb/debian
RUN mk-build-deps -t "apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends -y" -i /root/build-deb/debian/control

ENV BASE_IMAGE=${BASE_IMAGE}
ENV SYSBOX_RELEASE true

COPY --from=golang /usr/local/go /usr/local/go

# Let's explicitly set go-module feature to 'auto' mode (default as per Go 1.13) to avoid
# potential changes to this feature's default mode in the future. Even though we are
# relying on modules for the package's building process, we are enabling 'auto' mode to
# allow 'go get' traditional behavior (fetch entire git repo). Notice that we need git's
# metadata to allow a git-checkout operation further below.
ENV GO111MODULE=auto
ENV GOPROXY=${GOPROXY}
RUN go env -w GONOSUMDB=github.com/nestybox

# Install protoc compiler for gRPC.
RUN if [ "${arch}" = "amd64" ]; then arch_str="x86_64"; \
    elif [ "${arch}" = "arm64" ]; then arch_str="aarch_64"; \
    else echo "Unsupported platform: ${arch}"; exit; fi \
    && curl -LO https://gh-proxy.org/https://github.com/protocolbuffers/protobuf/releases/download/v3.15.8/protoc-3.15.8-linux-${arch_str}.zip \
    && unzip protoc-3.15.8-linux-${arch_str}.zip -d $HOME/.local \
    && export PATH="$PATH:$HOME/.local/bin" \
    && go install github.com/golang/protobuf/protoc-gen-go@latest \
    && export PATH="$PATH:$(go env GOPATH)/bin"

# Install Docker
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL ${DOCKER_APT_MIRROR}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && . /etc/os-release \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_APT_MIRROR} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/*
ADD https://gh-proxy.org/https://raw.githubusercontent.com/docker/docker-ce/master/components/cli/contrib/completion/bash/docker /etc/bash_completion.d/docker.sh

# Use the old definition for SECCOMP_NOTIF_ID_VALID in /usr/include/linux/seccomp.h
#
# This is needed because the definition changed in the mainline kernel
# on 06/2020 (from SECCOMP_IOR -> SECCOMP_IOW), and some distros we
# support have picked it up in their latest releases / kernels
# updates. The kernel change was backward compatible, so by using the
# old definition, we are guaranteed it will work on kernels before and
# after the change. On the other hand, if we were to use the new
# definition, seccomp notify would fail when sysbox runs in old
# kernels.
RUN sed -i 's/^#define SECCOMP_IOCTL_NOTIF_ID_VALID[ \t]*SECCOMP_IOW(2, __u64)/#define SECCOMP_IOCTL_NOTIF_ID_VALID   SECCOMP_IOR(2, __u64)/g' /usr/include/linux/seccomp.h

WORKDIR /root/build-deb
COPY sources/ /sources
COPY build-deb /root/build-deb/build-deb
COPY changelog_convert.sh /root/build-deb/changelog_convert.sh

ENTRYPOINT ["/root/build-deb/build-deb"]
