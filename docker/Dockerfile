FROM node:22-bookworm-slim
WORKDIR /app
COPY panel/package.json ./
COPY panel/server ./server
COPY panel/public ./public
COPY console/npq /usr/local/bin/npq
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates && rm -rf /var/lib/apt/lists/* \
  && chmod 755 /usr/local/bin/npq \
  && mkdir -p /data
ENV NODE_ENV=production PORT=51821 HOST=127.0.0.1 DATA_DIR=/data
EXPOSE 51821
VOLUME /data
CMD ["node", "server/index.js"]
