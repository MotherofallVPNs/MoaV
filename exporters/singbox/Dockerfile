FROM python:3.11-alpine

# No docker CLI here on purpose: this exporter no longer shells out to the
# container runtime. User attribution comes from the Clash API it already polls,
# which let the raw Docker socket mount be removed (see docker-compose.yml).

RUN pip install --no-cache-dir maxminddb

WORKDIR /app
COPY lib/geoip.py .
COPY singbox/main.py .

EXPOSE 9102

CMD ["python", "-u", "main.py"]
