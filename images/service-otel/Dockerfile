# Builds payment-gateway-service from the submodule source and layers the
# OpenTelemetry Java agent on top. The service jar is never modified: the agent
# is attached at runtime through JAVA_TOOL_OPTIONS, which the JVM reads on its
# own. That gives us distributed tracing (HTTP, JDBC, Tomcat) and trace_id /
# span_id in the logs without a single source change in the service.

FROM maven:3-eclipse-temurin-26 AS build
WORKDIR /build
COPY payment-gateway-service/pom.xml .
RUN mvn -B -q dependency:go-offline
COPY payment-gateway-service/src ./src
RUN mvn -B -q clean package -DskipTests

FROM eclipse-temurin:21-jre AS runtime
WORKDIR /app

# Pinned agent release. Bump deliberately, not automatically.
ARG OTEL_AGENT_VERSION=2.28.1
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar /opt/otel/opentelemetry-javaagent.jar

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system app && useradd --system --gid app app \
    && chmod 0644 /opt/otel/opentelemetry-javaagent.jar

COPY --from=build /build/target/payment-gateway-service.jar app.jar
USER app
EXPOSE 8080

# Two runtime-only settings, both applied without touching the service:
#   1. attach the OTel agent (OTEL_* env in compose configures where traces go);
#   2. turn on the http.server.requests latency histogram so Prometheus exposes
#      the _bucket series the RED dashboard needs for p95/p99.
ENV JAVA_TOOL_OPTIONS="-javaagent:/opt/otel/opentelemetry-javaagent.jar -Dmanagement.metrics.distribution.percentiles-histogram.http.server.requests=true"

HEALTHCHECK --interval=15s --timeout=3s --start-period=60s --retries=5 \
    CMD curl -fsS http://localhost:8080/actuator/health || exit 1

ENTRYPOINT ["java", "-jar", "app.jar"]
