FROM haskell:9.4 AS builder

ADD https://github.com/camfort/camfort/archive/refs/tags/v1.2.0.tar.gz .
RUN tar zxvf v1.2.0.tar.gz

RUN apt-get update && \
    apt-get install -y git-core \
                       libblas-dev \
                       libflint-dev \
                       libgf2x-dev \
                       liblapack-dev \
                       libmpfr-dev \
                       libntl-dev \
                       libtinfo-dev \
                       software-properties-common \
                       zlib1g-dev

RUN cabal new-update && cabal new-install hpack

WORKDIR /camfort-1.2.0

RUN /root/.cabal/bin/hpack
RUN cabal new-configure && cabal new-build && cabal new-install
RUN cp $(find /camfort-*/ -name camfort -type f -executable -print) /

FROM debian:buster-slim
RUN apt-get update && \
    apt-get install -y libflint-2.5.2 \
                       liblapack3 \
                       libgf2x1 \
                       libmpfr6 \
                       libntl35 \
                       libblas3 \
                       libtinfo5 && \
    rm -rf /var/lib/apt/lists/* && \
    apt-get clean

COPY --from=builder /camfort .

ENTRYPOINT ["/camfort"]
