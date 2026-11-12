FROM python:3.12-slim-bookworm
# virsh: VM start/stop; nft + iproute2: read the host guard in the host network namespace;
# openssh-client: probe the guest for the leak test.
RUN apt-get update \
 && apt-get install -y --no-install-recommends nftables iproute2 libvirt-clients openssh-client \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY app.py /app/app.py
EXPOSE 11088
CMD ["python3", "-u", "/app/app.py"]
