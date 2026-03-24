FROM alpine:3.20
RUN apk add --no-cache rclone bash
COPY sync.sh /sync.sh
RUN chmod +x /sync.sh
ENTRYPOINT ["/sync.sh"]
