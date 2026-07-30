FROM python:3.11-alpine

# No docker CLI: this exporter reads the stats snapshots and access log the
# xray container publishes, so it needs no access to the container runtime.

# Install docker CLI (needed to tail container logs)

RUN pip install --no-cache-dir maxminddb

WORKDIR /app
COPY lib/geoip.py .
COPY xray/main.py .

EXPOSE 9103

CMD ["python", "-u", "main.py"]
