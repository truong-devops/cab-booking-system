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

COPY package.json package-lock.json ./
COPY libs ./libs
COPY services/ai-service/package.json services/ai-service/package.json
RUN sh -c 'for i in 1 2 3; do npm install --omit=dev --workspaces --include-workspace-root --workspace @libs/validation --workspace @services/ai-service && exit 0; echo "npm install failed (attempt ${i}/3), retrying..."; sleep $((i * 10)); done; exit 1'

COPY services/ai-service ./services/ai-service
WORKDIR /app/services/ai-service
EXPOSE 3013
CMD ["node", "src/server.js"]
