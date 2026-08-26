FROM python:3.11-alpine

# Stdlib only: this exporter parses the proxy's persistent summary log (a
# read-only volume) and keeps a small JSON state file on its own volume. No
# pip deps, no docker socket, no network egress.

WORKDIR /app
COPY snowflake/main.py .

EXPOSE 9105

CMD ["python", "-u", "main.py"]
