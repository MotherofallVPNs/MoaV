FROM python:3.11-alpine

RUN pip install --no-cache-dir urllib3

WORKDIR /app
COPY main.py .
# Explicit modes: the checkout may be owner-only (umask 077) and COPY keeps that.
RUN chmod 644 /app/*.py

EXPOSE 9104

CMD ["python", "-u", "main.py"]
