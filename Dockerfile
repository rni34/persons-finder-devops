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

# Security: non-root user
RUN groupadd -r appgroup && useradd -r -g appgroup -u 1000 -d /app -s /sbin/nologin appuser

WORKDIR /app

# Copy Spring Boot layers in dependency order (best cache utilization)
COPY --from=builder /app/build/extracted/dependencies/ ./
COPY --from=builder /app/build/extracted/spring-boot-loader/ ./
COPY --from=builder /app/build/extracted/snapshot-dependencies/ ./
COPY --from=builder /app/build/extracted/application/ ./

# Own the app directory
RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 8080

# dumb-init wraps the JVM for proper SIGTERM forwarding
# JVM tuning: MaxRAMPercentage/InitialRAMPercentage for container-aware memory sizing
ENTRYPOINT ["dumb-init", "--", "java", \
    "-XX:MaxRAMPercentage=75.0", \
    "-XX:InitialRAMPercentage=25.0", \
    "org.springframework.boot.loader.JarLauncher"]
