FROM debian:trixie-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates curl git jq libssl-dev python3 time unzip \
  && rm -rf /var/lib/apt/lists/*

ENV MISE_DATA_DIR=/opt/mise MISE_YES=1 RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
WORKDIR /bench

COPY mise.toml ./
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
  && mise trust && mise install \
  && for tool in bun go node; do ln -s "$(mise which "$tool")" "/usr/local/bin/$tool"; done

COPY servers/rust/rust-toolchain.toml servers/rust/
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none \
  && cd servers/rust && rustup toolchain install

RUN git clone --depth 1 --branch 4.2.0 https://github.com/wg/wrk tools/wrk && make -C tools/wrk -j"$(nproc)"

COPY servers/bun/package.json servers/bun/bun.lock servers/bun/
RUN cd servers/bun && bun install --frozen-lockfile
COPY servers/node/package.json servers/node/package-lock.json servers/node/
RUN cd servers/node && mise exec -- npm ci
COPY servers/go/go.mod servers/go/go.sum servers/go/
RUN cd servers/go && go mod download

COPY servers/go servers/go
RUN cd servers/go && CGO_ENABLED=1 go build -pgo=auto -trimpath -o /bench/bin/go-server ./
COPY servers/rust servers/rust
RUN servers/rust/build.sh && rm -rf servers/rust/target
COPY servers/bun servers/bun
COPY servers/node servers/node
COPY bench bench
