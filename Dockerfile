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

# Security: non-root user
RUN groupadd -r appgroup && useradd -r -g appgroup -d /app -s /sbin/nologin appuser

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

HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:8080/actuator/health/liveness || exit 1

ENTRYPOINT ["java", "org.springframework.boot.loader.JarLauncher"]
