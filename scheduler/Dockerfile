FROM postgres:16

# cron: runs our backup/restore schedule.
RUN apt-get update \
    && apt-get install -y --no-install-recommends cron ca-certificates curl python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir --break-system-packages psycopg2-binary python-dotenv

# Install just the `docker` CLI client binary,
# so we can `docker exec` into the database container over the host's
# mounted socket. Debian's own `docker.io` package only recommends, but
# doesn't depend on, the package that provides this binary, so pulling the
# official static binary directly is more reliable than relying on apt here.
RUN curl -fsSL https://download.docker.com/linux/static/stable/x86_64/docker-27.3.1.tgz -o /tmp/docker.tgz \
    && tar xzf /tmp/docker.tgz --strip-components=1 -C /usr/local/bin docker/docker \
    && chmod +x /usr/local/bin/docker \
    && rm /tmp/docker.tgz

COPY scheduler/crontab /etc/cron.d/backup-cron
RUN chmod 0644 /etc/cron.d/backup-cron

# Run cron in the foreground so it's the container's main (PID 1) process.
CMD ["cron", "-f"]
