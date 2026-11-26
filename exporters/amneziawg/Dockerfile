FROM python:3.11-alpine

# No docker CLI: this exporter reads the state file its tunnel container
# publishes, so it needs no access to the container runtime.

# Install docker CLI (to run docker exec)

RUN pip install --no-cache-dir maxminddb

WORKDIR /app
COPY lib/geoip.py .
COPY amneziawg/main.py .
# Explicit modes: the checkout may be owner-only (umask 077) and COPY keeps that.
RUN chmod 644 /app/*.py

EXPOSE 9587

CMD ["python", "-u", "main.py"]
