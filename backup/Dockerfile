# Backup-Dienst: gleiche Postgres-Version wie die Datenbank, damit pg_dump exakt passt.
FROM postgres:18.6-alpine3.24

RUN apk add --no-cache bash age sqlite openssh-client \
 # uid 1000 wie die Apps (node): sqlite3 legt sonst root-eigene -wal/-shm-Dateien an,
 # an denen focus und quarantine scheitern würden. ssh braucht einen passwd-Eintrag.
 && adduser -D -u 1000 backup \
 # Vorlage für das Volume backup_status: ein neues Volume übernimmt den Eigentümer
 && install -d -o backup -g backup /status

COPY known_hosts age-recipients.txt /etc/backup/
COPY backup.sh /usr/local/bin/backup

USER backup
ENTRYPOINT ["/usr/local/bin/backup"]
CMD ["schedule"]
