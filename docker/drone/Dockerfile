# Dockerfile for Azure/batch-shipyard
FROM alpine:3.6
MAINTAINER Hieu Huynh <hieu.huynh@esmartsystems.com>

ARG GIT_BRANCH

RUN apk update \
    && apk add --update --no-cache \
        musl build-base python3 python3-dev libressl-dev libffi-dev \
        ca-certificates libressl openssh-client rsync git bash \
    && git clone -b $GIT_BRANCH --single-branch --depth 5 https://github.com/hieuhc/batch-shipyard.git /batch-shipyard \
    && cd /batch-shipyard \
    && rm -rf .git .github \
    && rm -f .git* .travis.yml install* \
    && pip3 install --no-cache-dir -r requirements.txt \
    && pip3 install --no-cache-dir --no-deps -r req_nodeps.txt \
    && apk del --purge build-base python3-dev libressl-dev libffi-dev git \
    && rm /var/cache/apk/*
