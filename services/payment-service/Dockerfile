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

# Copy workspace manifests needed for dependency install
COPY package*.json ./
COPY services/payment-service/package*.json ./services/payment-service/
COPY libs/validation/package*.json ./libs/validation/
COPY libs/http/package*.json ./libs/http/
COPY libs/observability/package*.json ./libs/observability/

RUN sh -c 'for i in 1 2 3; do npm install && exit 0; echo "npm install failed (attempt ${i}/3), retrying..."; sleep $((i * 10)); done; exit 1'

# Copy source
COPY services/payment-service ./services/payment-service
COPY libs/validation ./libs/validation
COPY libs/http ./libs/http
COPY libs/observability ./libs/observability
COPY contracts/events ./contracts/events

WORKDIR /app/services/payment-service
EXPOSE 3007
CMD ["npm", "run", "start"]
