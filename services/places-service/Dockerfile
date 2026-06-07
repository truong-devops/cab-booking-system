FROM node:20-alpine
WORKDIR /app

ENV NPM_CONFIG_FETCH_RETRIES=5 \
  NPM_CONFIG_FETCH_RETRY_FACTOR=2 \
  NPM_CONFIG_FETCH_RETRY_MINTIMEOUT=20000 \
  NPM_CONFIG_FETCH_RETRY_MAXTIMEOUT=120000 \
  NPM_CONFIG_FETCH_TIMEOUT=300000 \
  NPM_CONFIG_MAXSOCKETS=10 \
  NPM_CONFIG_AUDIT=false \
  NPM_CONFIG_FUND=false

COPY services/places-service/package.json ./package.json
RUN sh -c 'for i in 1 2 3; do npm install --omit=dev && exit 0; echo "npm install failed (attempt ${i}/3), retrying..."; sleep $((i * 10)); done; exit 1'

COPY services/places-service/src ./src

EXPOSE 3014
CMD ["node", "src/server.js"]
