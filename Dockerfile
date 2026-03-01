# ---- Stage 1: Build ----
FROM eclipse-temurin:11.0.25_9-jdk-jammy AS builder

WORKDIR /app

# Copy gradle wrapper and config first (layer caching)
COPY gradle/ gradle/
COPY gradlew build.gradle.kts settings.gradle.kts ./
RUN chmod +x gradlew && ./gradlew dependencies --no-daemon || true

# Copy source and build
COPY src/ src/
RUN ./gradlew build --no-daemon -x test \
    && mkdir -p build/extracted \
    && java -Djarmode=layertools -jar build/libs/PersonsFinder-0.0.1-SNAPSHOT.jar extract --destination build/extracted

# ---- Stage 2: Runtime ----
FROM eclipse-temurin:11.0.25_9-jre-jammy AS runtime

# OCI image labels for traceability
LABEL org.opencontainers.image.title="Persons Finder"
LABEL org.opencontainers.image.description="Persons Finder API — Spring Boot on EKS"
LABEL org.opencontainers.image.version="0.0.1-SNAPSHOT"
LABEL org.opencontainers.image.source="https://github.com/hakunishikawa/persons-finder-devops"
LABEL org.opencontainers.image.licenses="MIT"

# Install dumb-init for proper PID 1 signal handling
RUN apt-get update && apt-get install -y --no-install-recommends dumb-init \
    && rm -rf /var/lib/apt/lists/*

# CIS Docker Benchmark 4.8: Remove setuid/setgid bits (defense-in-depth)
# K8s securityContext already blocks privilege escalation, but stripping these
# from the image protects against misuse outside K8s (local dev, docker-compose)
RUN find / -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true

# Security: non-root user
RUN groupadd -r appgroup && useradd -r -g appgroup -u 1000 -d /app -s /sbin/nologin appuser

WORKDIR /app

# Copy Spring Boot layers in dependency order (best cache utilization)
# --chown avoids a separate chown layer, reducing image size
COPY --from=builder --chown=appuser:appgroup /app/build/extracted/dependencies/ ./
COPY --from=builder --chown=appuser:appgroup /app/build/extracted/spring-boot-loader/ ./
COPY --from=builder --chown=appuser:appgroup /app/build/extracted/snapshot-dependencies/ ./
COPY --from=builder --chown=appuser:appgroup /app/build/extracted/application/ ./

USER appuser

EXPOSE 8080

# dumb-init wraps the JVM for proper SIGTERM forwarding
# JVM tuning: MaxRAMPercentage/InitialRAMPercentage for container-aware memory sizing
# G1GC: JDK 11 ergonomics selects SerialGC (single-threaded) when container memory < 2GB.
# With 1Gi limit, this causes high tail latency under concurrent load. Force G1GC explicitly.
# JMX disabled: monitoring is via Prometheus (ServiceMonitor + /actuator/prometheus).
# JMX MBean registration is unused overhead — saves ~200-500ms startup and reduces memory.
ENTRYPOINT ["dumb-init", "--", "java", \
    "-XX:+UseG1GC", \
    "-XX:MaxRAMPercentage=75.0", \
    "-XX:InitialRAMPercentage=25.0", \
    "-XX:+ExitOnOutOfMemoryError", \
    "-Dspring.jmx.enabled=false", \
    "org.springframework.boot.loader.JarLauncher"]
