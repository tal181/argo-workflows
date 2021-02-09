
ARG DOCKER_CHANNEL=stable
ARG DOCKER_VERSION=18.09.1
# NOTE: kubectl version should be one minor version less than https://storage.googleapis.com/kubernetes-release/release/stable.txt
ARG KUBECTL_VERSION=1.19.6
ARG JQ_VERSION=1.6

FROM golang:1.15.7 as builder

RUN apt-get update && apt-get --no-install-recommends install -y \
    git \
    make \
    apt-utils \
    apt-transport-https \
    ca-certificates \
    wget \
    gcc \
    zip && \
    apt-get clean \
    && rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/* \
        /usr/share/man \
        /usr/share/doc \
        /usr/share/doc-base

WORKDIR /tmp

# https://blog.container-solutions.com/faster-builds-in-docker-with-go-1-11
WORKDIR /go/src/github.com/argoproj/argo
COPY go.mod .
COPY go.sum .
RUN go mod download

WORKDIR /go/src/github.com/argoproj/argo
COPY . .

####################################################################################################

FROM debian:10.7-slim as argoexec-base

ARG DOCKER_CHANNEL
ARG DOCKER_VERSION
ARG KUBECTL_VERSION
ARG JQ_VERSION

RUN apt-get update && \
    apt-get --no-install-recommends install -y curl procps git apt-utils apt-transport-https ca-certificates tar mime-support && \
    apt-get clean \
    && rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/* \
        /usr/share/man \
        /usr/share/doc \
        /usr/share/doc-base

COPY hack/recurl.sh .
RUN if [ $(uname -m) = ppc64le ] || [ $(uname -m)  = s390x ]; then \
        ./recurl.sh docker.tgz https://download.docker.com/$(uname -s|tr '[:upper:]' '[:lower:]')/static/${DOCKER_CHANNEL}/$(uname -m) docker-18.06.3-ce.tgz; \
    else \
        ./recurl.sh docker.tgz https://download.docker.com/$(uname -s|tr '[:upper:]' '[:lower:]')/static/${DOCKER_CHANNEL}/$(uname -m)/docker-${DOCKER_VERSION}.tgz; \
    fi && \
    tar --extract --file docker.tgz --strip-components 1 --directory /usr/local/bin/ && \
    rm docker.tgz

RUN ./recurl.sh /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/v${KUBECTL_VERSION}/bin/$(uname -s|tr '[:upper:]' '[:lower:]')/$(uname -m)/kubectl
RUN ./recurl.sh /usr/local/bin/jq https://github.com/stedolan/jq/releases/download/jq-${JQ_VERSION}/jq-linux64
RUN rm recurl.sh

COPY hack/ssh_known_hosts /etc/ssh/
COPY hack/nsswitch.conf /etc/


####################################################################################################

FROM node:14.0.0 as argo-ui

COPY ui/package.json ui/yarn.lock ui/

RUN JOBS=max yarn --cwd ui install --network-timeout 1000000

COPY ui ui
COPY api api

RUN JOBS=max yarn --cwd ui build

####################################################################################################

FROM builder as argoexec-build

RUN --mount=type=cache,target=/root/.cache/go-build make dist/argoexec

####################################################################################################

FROM builder as workflow-controller-build

RUN --mount=type=cache,target=/root/.cache/go-build make dist/workflow-controller

####################################################################################################

FROM builder as argocli-build

RUN mkdir -p ui/dist
COPY --from=argo-ui ui/dist/app ui/dist/app
# stop make from trying to re-build this without yarn installed
RUN touch ui/dist/node_modules.marker
RUN touch ui/dist/app/index.html
RUN --mount=type=cache,target=/root/.cache/go-build make dist/argo

####################################################################################################

FROM argoexec-base as argoexec

COPY --from=argoexec-build /go/src/github.com/argoproj/argo/dist/argoexec /usr/local/bin/

ENTRYPOINT [ "argoexec" ]

####################################################################################################

FROM scratch as workflow-controller

USER 8737

COPY --from=workflow-controller-build /usr/share/zoneinfo /usr/share/
COPY --chown=8737 --from=workflow-controller-build /go/src/github.com/argoproj/argo/dist/workflow-controller /bin/

ENTRYPOINT [ "workflow-controller" ]

####################################################################################################

FROM scratch as argocli

USER 8737

COPY hack/ssh_known_hosts /etc/ssh/
COPY hack/nsswitch.conf /etc/
COPY --from=argocli-build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=argocli-build --chown=8737 /go/src/github.com/argoproj/argo/argo-server.crt /
COPY --from=argocli-build --chown=8737 /go/src/github.com/argoproj/argo/argo-server.key /
COPY --from=argocli-build /go/src/github.com/argoproj/argo/dist/argo /bin/

ENTRYPOINT [ "argo" ]
