FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl jq python3 python3-pip bash git gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install OpenStack CLI and Ironic client
RUN pip3 install --no-cache-dir \
    python-openstackclient \
    python-ironicclient \
    python-neutronclient \
    python-glanceclient \
    yq

# Install GNU parallel
RUN apt-get update && apt-get install -y --no-install-recommends parallel && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY baremetal.sh /app/baremetal.sh
RUN chmod +x /app/baremetal.sh

# Default entry, can be overridden
ENTRYPOINT ["/app/baremetal.sh"]

