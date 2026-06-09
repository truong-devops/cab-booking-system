FROM postgres:16-alpine

WORKDIR /opt/cab-postgres

COPY infra/postgres/pro-init /docker-entrypoint-initdb.d

RUN chmod +x \
  /docker-entrypoint-initdb.d/01-create-service-databases.sh \
  /docker-entrypoint-initdb.d/02-apply-service-schemas.sh \
  /docker-entrypoint-initdb.d/03-bootstrap-auth-admin.sh

ENTRYPOINT ["/bin/sh"]

