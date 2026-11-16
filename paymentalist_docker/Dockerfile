ARG SCUTTLE_COMMIT=109f090ca69da13f5df3ffb8ff3ab345bc3f097b
ARG CARGO_TOML_SHA256=2862806e52048e3d8e5fd7df0e686d0e0abea4e21cd0d8cc364d4c985f5b48e4
ARG CARGO_LOCK_SHA256=93202cbd24953290738c75b3aaf981f5e141c736a6091c46526f28cf2a2e4cc9

FROM rust:1.86.0-slim AS builder
ARG SCUTTLE_COMMIT
ARG CARGO_TOML_SHA256
ARG CARGO_LOCK_SHA256

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    pkg-config \
    libssl-dev \
    procps \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/paymentalist

COPY Cargo.toml Cargo.lock ./
RUN printf '%s  Cargo.toml\n%s  Cargo.lock\n' "$CARGO_TOML_SHA256" "$CARGO_LOCK_SHA256" | sha256sum -c - \
 && grep -F "rev = \"$SCUTTLE_COMMIT\"" Cargo.toml \
 && cargo fetch --locked

COPY ./src ./src
COPY ./config ./config
COPY ./test ./test

RUN cargo build --release --locked

FROM debian:bookworm-slim AS runtime
ARG SCUTTLE_COMMIT
ARG CARGO_TOML_SHA256
ARG CARGO_LOCK_SHA256
LABEL org.satoshiportal.scuttle.commit=$SCUTTLE_COMMIT \
      org.satoshiportal.ark-lib.commit=$SCUTTLE_COMMIT \
      org.satoshiportal.cargo-toml.sha256=$CARGO_TOML_SHA256 \
      org.satoshiportal.cargo-lock.sha256=$CARGO_LOCK_SHA256

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /usr/src/paymentalist/target/release/paymentalist /usr/local/bin/paymentalist
COPY --from=builder /usr/src/paymentalist/target/release/create_reverse_swap /usr/local/bin/create_reverse_swap
COPY --from=builder /usr/src/paymentalist/config /app/config

RUN chmod +x /usr/local/bin/paymentalist
RUN chmod +x /usr/local/bin/create_reverse_swap

ENV RUST_LOG=info,paymentalist=debug,tower_http=debug

CMD ["/usr/local/bin/paymentalist"]