FROM confluentinc/cp-kafka:7.6.1

USER root
WORKDIR /opt/kafka-bootstrap

COPY infra/kafka/bootstrap-topics.sh /opt/kafka-bootstrap/bootstrap-topics.sh
RUN chmod +x /opt/kafka-bootstrap/bootstrap-topics.sh

ENTRYPOINT ["/bin/sh"]

