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

COPY services/user-service/package*.json ./
RUN sh -c 'for i in 1 2 3; do npm install && exit 0; echo "npm install failed (attempt ${i}/3), retrying..."; sleep $((i * 10)); done; exit 1'

COPY libs ./libs
COPY services/user-service/src ./src
COPY services/user-service/migrations ./migrations

EXPOSE 4004
CMD ["npm", "run", "start"]
