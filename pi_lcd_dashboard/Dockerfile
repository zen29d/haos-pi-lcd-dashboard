FROM ghcr.io/home-assistant/base:latest
RUN apk add --no-cache python3 py3-libgpiod py3-pillow py3-websocket-client font-inter font-dejavu
COPY run.sh /run.sh
RUN chmod a+x /run.sh
CMD ["/run.sh"]
