FROM python:3.11-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

RUN apt-get update && apt-get install -y --no-install-recommends \
    sshpass \
    openssh-client \
    rsync \
    dnsmasq \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependency layer — cached until pyproject.toml or uv.lock changes
COPY pyproject.toml uv.lock ./
RUN uv pip install --system -r pyproject.toml --no-install-project 2>/dev/null \
 || uv pip install --system anthropic pyserial

# Source layer
COPY . .
RUN uv pip install --system --no-deps .

VOLUME ["/app/backups", "/app/results"]

ENTRYPOINT ["coldbrew-mule"]
CMD ["--help"]
