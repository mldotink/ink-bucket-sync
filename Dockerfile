FROM alpine:3.21
RUN apk add --no-cache bash inotify-tools curl unzip \
    && curl -fsSL https://downloads.rclone.org/rclone-current-linux-amd64.zip -o /tmp/rclone.zip \
    && unzip -j /tmp/rclone.zip '*/rclone' -d /usr/local/bin/ \
    && rm -rf /tmp/rclone.zip \
    && apk del curl unzip
COPY sync.sh /sync.sh
RUN chmod +x /sync.sh && rm -rf /tmp/.cache
ENV HOME=/tmp
ENTRYPOINT ["/sync.sh"]
